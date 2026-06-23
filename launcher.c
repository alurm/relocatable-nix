// SPDX-License-Identifier: MIT
//
// relocatable-nix launcher
//
// A tiny self-locating shim that replaces a script's shebang. It finds its own
// location, reads a sidecar describing how to run the script's interpreter
// relative to itself, and execs — so the package works at any store prefix.
//
// The sidecar lives at "<self>.rb" and is a list of NUL-separated tokens whose
// first token selects a mode:
//
//   direct mode  ("d"):
//       d \0 <interp-rel> \0 [<arg> \0 ...] <script-rel> \0
//     exec: <dir>/<interp-rel>  <args...>  <dir>/<script-rel>  <user args...>
//     (used for interpreters with no dynamic loader to chase, e.g. static)
//
//   loader mode  ("l"):
//       l \0 <loader-rel> \0 <libdirs-rel> \0 <interp-rel> \0 [<arg>\0 ...] <script-rel> \0
//     exec: <dir>/<loader-rel> --library-path <abs libdirs>
//             --argv0 <dir>/<interp-rel> <dir>/<interp-rel> <args...>
//             <dir>/<script-rel> <user args...>
//     <libdirs-rel> is a ':'-separated list of dirs relative to the launcher;
//     each is made absolute and passed to ld.so via --library-path. This makes
//     a *dynamically* linked interpreter relocatable without patching any
//     binary: ld.so is invoked explicitly (bypassing the absolute PT_INTERP)
//     and finds libraries under the relocated prefix.
//
// All paths are constructed by prefixing the launcher's own directory; we do
// not realpath() the targets, letting the kernel resolve ".." lazily.

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

static void *xmalloc(size_t n) {
	void *p = malloc(n);
	if (!p)
		die("malloc");
	return p;
}

// Absolute, canonical path of the running executable into buf.
static void self_path(char *buf, size_t bufsz) {
#if defined(__APPLE__)
	char raw[PATH_MAX];
	uint32_t sz = sizeof(raw);
	if (_NSGetExecutablePath(raw, &sz) != 0)
		die("_NSGetExecutablePath");
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
	char *buf = xmalloc(cap);
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

// Split NUL-separated buffer into a token array (pointers into buf). Requires a
// trailing NUL after the final token (the hook always writes one).
static char **split_tokens(char *buf, size_t len, size_t *count) {
	size_t n = 0;
	for (size_t i = 0; i < len; i++)
		if (buf[i] == '\0')
			n++;
	char **toks = xmalloc((n + 1) * sizeof(char *));
	size_t t = 0, start = 0;
	for (size_t i = 0; i < len; i++) {
		if (buf[i] == '\0') {
			toks[t++] = buf + start;
			start = i + 1;
		}
	}
	*count = t;
	toks[t] = NULL;
	return toks;
}

static char *join(const char *dir, const char *rel) {
	size_t need = strlen(dir) + 1 + strlen(rel) + 1;
	char *p = xmalloc(need);
	snprintf(p, need, "%s/%s", dir, rel);
	return p;
}

// Turn a ':'-separated list of launcher-relative dirs into a ':'-separated list
// of absolute dirs (each prefixed with <dir>/).
static char *abs_libpath(const char *dir, const char *rel_list) {
	// Worst case: every entry gains strlen(dir)+1 chars.
	size_t entries = 1;
	for (const char *p = rel_list; *p; p++)
		if (*p == ':')
			entries++;
	size_t need = strlen(rel_list) + entries * (strlen(dir) + 1) + 1;
	char *out = xmalloc(need);
	out[0] = '\0';

	char *copy = strdup(rel_list);
	if (!copy)
		die("strdup");
	int first = 1;
	for (char *tok = strtok(copy, ":"); tok; tok = strtok(NULL, ":")) {
		if (!first)
			strcat(out, ":");
		strcat(out, dir);
		strcat(out, "/");
		strcat(out, tok);
		first = 0;
	}
	free(copy);
	return out;
}

int main(int argc, char **argv) {
	if (argv[0])
		progname = argv[0];

	char self[PATH_MAX];
	self_path(self, sizeof(self));

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

	if (ntok < 1) {
		fprintf(stderr, "%s: empty sidecar\n", progname);
		return 127;
	}

	size_t user = (argc > 1) ? (size_t)(argc - 1) : 0;
	const char *mode = toks[0];

	if (strcmp(mode, "d") == 0) {
		// d, interp-rel, [args...], script-rel
		if (ntok < 3) {
			fprintf(stderr, "%s: malformed direct sidecar\n", progname);
			return 127;
		}
		char *interp = join(selfdir, toks[1]);
		char *script = join(selfdir, toks[ntok - 1]);
		size_t nargs = ntok - 3;

		char **na = xmalloc((1 + nargs + 1 + user + 1) * sizeof(char *));
		size_t k = 0;
		na[k++] = interp;
		for (size_t i = 0; i < nargs; i++)
			na[k++] = toks[2 + i];
		na[k++] = script;
		for (size_t i = 0; i < user; i++)
			na[k++] = argv[1 + i];
		na[k] = NULL;
		execv(interp, na);
		die("execv");
	} else if (strcmp(mode, "l") == 0) {
		// l, loader-rel, libdirs-rel, interp-rel, [args...], script-rel
		if (ntok < 5) {
			fprintf(stderr, "%s: malformed loader sidecar\n", progname);
			return 127;
		}
		char *loader = join(selfdir, toks[1]);
		char *libpath = abs_libpath(selfdir, toks[2]);
		char *interp = join(selfdir, toks[3]);
		char *script = join(selfdir, toks[ntok - 1]);
		size_t nargs = ntok - 5;

		// loader --library-path L --argv0 interp interp args... script user...
		char **na = xmalloc((6 + nargs + 1 + user + 1) * sizeof(char *));
		size_t k = 0;
		na[k++] = loader;
		na[k++] = "--library-path";
		na[k++] = libpath;
		na[k++] = "--argv0";
		na[k++] = interp;
		na[k++] = interp;
		for (size_t i = 0; i < nargs; i++)
			na[k++] = toks[4 + i];
		na[k++] = script;
		for (size_t i = 0; i < user; i++)
			na[k++] = argv[1 + i];
		na[k] = NULL;
		execv(loader, na);
		die("execv");
	}

	fprintf(stderr, "%s: unknown sidecar mode '%s'\n", progname, mode);
	return 127;
}
