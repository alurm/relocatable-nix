// SPDX-License-Identifier: MIT
//
// relocatable-nix launcher
//
// A tiny self-locating shim that replaces a script's shebang. It finds its own
// location, reads a sidecar describing the interpreter (relative to itself) and
// the real script, then execs the interpreter — mirroring what the kernel does
// for a `#!` line, but resolved relative to where the files physically live, so
// the package works at any store prefix.
//
// Sidecar format (NUL-separated tokens), located at "<self>.rb":
//
//     <interp-rel>\0[<arg>\0 ...]<script-rel>\0
//
// i.e. the first token is the interpreter path relative to the launcher's
// directory, the last token is the script path relative to the same directory,
// and any tokens in between are fixed interpreter arguments (e.g. from a
// resolved `env -S` line).
//
// The resulting exec is:
//
//     execv(<dir>/<interp-rel>,
//           { <dir>/<interp-rel>, <args>..., <dir>/<script-rel>,
//             <original argv[1..]> })
//
// We deliberately do not realpath() the targets: execv lets the kernel resolve
// ".." lazily, and keeping the constructed path means the script sees a clean
// relative-looking $0 rather than a fully canonicalized one.

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

static const char *progname = "relocatable-nix-launcher";

static void die(const char *msg) {
	fprintf(stderr, "%s: %s: %s\n", progname, msg, strerror(errno));
	exit(127);
}

// Write the absolute, canonical path of the running executable into buf.
static void self_path(char *buf, size_t bufsz) {
#if defined(__APPLE__)
	char raw[PATH_MAX];
	uint32_t sz = sizeof(raw);
	if (_NSGetExecutablePath(raw, &sz) != 0)
		die("_NSGetExecutablePath");
	// _NSGetExecutablePath may return a non-canonical path (symlinks, ..),
	// so canonicalize it.
	if (!realpath(raw, buf))
		die("realpath");
#elif defined(__linux__)
	ssize_t len = readlink("/proc/self/exe", buf, bufsz - 1);
	if (len < 0)
		die("readlink /proc/self/exe");
	buf[len] = '\0';
#else
#error "unsupported platform: no self-path mechanism"
#endif
	(void)bufsz;
}

// Read the whole sidecar into a malloc'd buffer; sets *len to its size.
static char *read_sidecar(const char *self, size_t *len) {
	char path[PATH_MAX];
	int n = snprintf(path, sizeof(path), "%s.rb", self);
	if (n < 0 || (size_t)n >= sizeof(path)) {
		errno = ENAMETOOLONG;
		die("sidecar path");
	}

	int fd = open(path, O_RDONLY);
	if (fd < 0)
		die("open sidecar");

	size_t cap = 4096, used = 0;
	char *buf = malloc(cap);
	if (!buf)
		die("malloc");

	for (;;) {
		if (used == cap) {
			cap *= 2;
			char *nbuf = realloc(buf, cap);
			if (!nbuf)
				die("realloc");
			buf = nbuf;
		}
		ssize_t r = read(fd, buf + used, cap - used);
		if (r < 0)
			die("read sidecar");
		if (r == 0)
			break;
		used += (size_t)r;
	}
	close(fd);
	*len = used;
	return buf;
}

// Split the NUL-separated sidecar into a token array (pointers into buf).
static char **split_tokens(char *buf, size_t len, size_t *count) {
	size_t n = 0;
	for (size_t i = 0; i < len; i++)
		if (buf[i] == '\0')
			n++;
	// Tolerate a missing trailing NUL on the last token.
	if (len > 0 && buf[len - 1] != '\0')
		n++;

	char **toks = calloc(n + 1, sizeof(char *));
	if (!toks)
		die("calloc");

	size_t t = 0, start = 0;
	for (size_t i = 0; i < len; i++) {
		if (buf[i] == '\0') {
			toks[t++] = buf + start;
			start = i + 1;
		}
	}
	if (start < len) {
		// Last token had no trailing NUL; terminate it in place is not
		// possible without writing past the buffer, so the caller relies
		// on read_sidecar having read exactly `len` bytes. We require a
		// trailing NUL in practice; guard anyway.
		toks[t++] = buf + start;
	}
	*count = t;
	return toks;
}

// Join "<dir>/<rel>" into a fresh string.
static char *join(const char *dir, const char *rel) {
	size_t need = strlen(dir) + 1 + strlen(rel) + 1;
	char *p = malloc(need);
	if (!p)
		die("malloc");
	snprintf(p, need, "%s/%s", dir, rel);
	return p;
}

int main(int argc, char **argv) {
	if (argv[0])
		progname = argv[0];

	char self[PATH_MAX];
	self_path(self, sizeof(self));

	// dir = dirname(self); mutate a copy.
	char selfdir[PATH_MAX];
	strncpy(selfdir, self, sizeof(selfdir) - 1);
	selfdir[sizeof(selfdir) - 1] = '\0';
	char *slash = strrchr(selfdir, '/');
	if (!slash) {
		fprintf(stderr, "%s: self path has no '/': %s\n", progname, self);
		return 127;
	}
	*slash = '\0';

	size_t slen;
	char *sbuf = read_sidecar(self, &slen);

	size_t ntok;
	char **toks = split_tokens(sbuf, slen, &ntok);
	if (ntok < 2) {
		fprintf(stderr, "%s: malformed sidecar (need interp and script)\n",
			progname);
		return 127;
	}

	// toks[0]            = interp-rel
	// toks[1..ntok-2]    = interpreter args
	// toks[ntok-1]       = script-rel
	char *interp = join(selfdir, toks[0]);
	char *script = join(selfdir, toks[ntok - 1]);
	size_t nargs = ntok - 2; // interpreter args between interp and script

	// new argv: interp, args..., script, original argv[1..], NULL
	size_t user = (argc > 1) ? (size_t)(argc - 1) : 0;
	size_t total = 1 + nargs + 1 + user + 1;
	char **na = calloc(total, sizeof(char *));
	if (!na)
		die("calloc");

	size_t k = 0;
	na[k++] = interp;
	for (size_t i = 0; i < nargs; i++)
		na[k++] = toks[1 + i];
	na[k++] = script;
	for (size_t i = 0; i < user; i++)
		na[k++] = argv[1 + i];
	na[k] = NULL;

	execv(interp, na);
	die("execv"); // only reached on failure
	return 127;
}
