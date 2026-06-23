# relocatable-nix

Make Nix executables **relocatable** — runnable from any store prefix, not just
`/nix/store` — by replacing them with a tiny self-locating launcher.

The launcher is interpreter-agnostic: it finds itself at runtime
(`/proc/self/exe` on Linux, `_NSGetExecutablePath` on macOS) and runs the real
program resolved **relative to its own location** — the same idea as ELF
`$ORIGIN`, but in userspace, needing no kernel changes and no privileges. It
works for two cases with the same mechanism:

- **shebang scripts** — resolve the interpreter relative to the script;
- **dynamic ELF binaries** — invoke `ld.so` explicitly with a relative
  `--library-path` (loader mode), bypassing the absolute `PT_INTERP`/`RPATH`.

Both shebang scripts and dynamic ELF binaries are wrapped by the build hook;
the library closure is derived automatically from each binary's `RPATH`, so no
manual closure plumbing is needed. (ELF wrapping comes with a `/proc/self/exe`
caveat — see *ELF binaries*.)

> **Scope.** This relocates *executable entry points*. It does **not** by itself
> make a whole closure relocatable: absolute symlinks and store-path strings
> embedded in data files (`.pc`, `.desktop`, configs, caches) remain, and
> mutable system state (`/var`, `/etc`) is a separate concern nixpkgs handles at
> activation, not a store property. Full store relocatability is the broader
> problem tracked in [NixOS/nix#9549](https://github.com/NixOS/nix/issues/9549);
> this tool is one component of it, best suited to self-contained script/CLI
> packages. See *Scope & limits*.

## How it works

For each executable, the build hook:

1. moves the real file aside (`bin/foo` → `bin/.foo.script` or `bin/.foo.real`),
2. drops the launcher at the original path (`bin/foo`),
3. writes a NUL-separated manifest (`bin/.foo.reloc`) describing how to run it.

The manifest keeps the launcher binary byte-for-byte identical for every
executable (per-item config lives in data, not code), so the hook just copies
one prebuilt binary — no compiler, no per-item build. It has three modes:

- **`d` direct** — static interpreter: exec it directly.
- **`l` loader** — dynamic interpreter: `ld.so --library-path <farm> … <interp> <script>`.
- **`e` elf** — dynamic ELF binary: `ld.so --library-path <farm> … <prog>`.

No absolute paths are baked in, so the package works wherever it is extracted.

## Usage

Per-package (opt-in):

```nix
stdenv.mkDerivation {
  dontPatchShebangs = true;
  nativeBuildInputs = [ relocatable.packages.${system}.relocatableShebangsHook ];
  postFixup = "relocateExecutables $out/bin";
}
```

Global — wrap **every** package via overlay (auto-runs in fixup; opt out per
derivation with `dontRelocate = true`):

```nix
nixpkgs.overlays = [ relocatable.overlays.default ];
```

> ⚠️ The global overlay rebuilds the world and wraps build-time tools too. If a
> wrapped ELF reads `/proc/self/exe` (clang, runc, Chromium, the JVM, …) it can
> break — see *ELF binaries*. Treat the overlay as experimental; prefer the
> per-package hook for anything you depend on.

## Try it

```sh
nix build .#launcher          # the static launcher
nix build .#demo              # a demo package built through the hook
./result/bin/hello            # runs in place

nix flake check               # runs the test suite (see below)
```

The `example/` directory is a standalone consumer flake that takes
`relocatable-nix` as an input and demonstrates the full story:

```sh
cd example
nix build .#           # builds `greet` through the hook
nix run .#prove        # copies the closure to a NON-/nix prefix and runs it
```

## Populating a relocatable store

The point of all this is to take a closure and run it from a different prefix.
Build into your normal store, then **copy** the closure out — do *not* try to
build directly into the target store:

```sh
dest=/tmp/relocated-store
nix build .#demo
nix copy --no-check-sigs --to "$dest" ./result
"$dest/nix/store/$(basename "$(readlink -f result)")/bin/hello"   # runs from $dest
```

- `--no-check-sigs` is required because locally-built paths are not signed by a
  trusted key.
- For a fully flattened layout (no `/nix/store` suffix at all), see the
  `example/` flake's `prove` app, which copies the closure to a temp
  `relocated-store/<hash>` and runs it there.

### Why not `nix build --store <dir>`?

Building *into* an alternative store does not work for this on a typical setup:
the build sandbox exposes the real `/nix/store` read-only, so any output path
that already exists in your real store collides and the builder fails with
`Permission denied` writing its own `$out`. This is a store/sandbox interaction,
not a property of the package. Build normally and `nix copy` instead.

## Tests

`nix flake check` runs:

- **`launcher-unit`** — drives the launcher in isolation: argument forwarding,
  exit-code propagation, relocation (move the tree and re-run), and a clean
  error when the manifest is missing.
- **`relocation`** — static interpreter; build through the hook, copy the
  closure to a non-`/nix/store` prefix, run there, assert the interpreter
  resolved under the new prefix.
- **`relocation-dynamic`** — dynamic interpreter (`bash`) relocated via
  loader mode.
- **`relocation-interscript`** — a script that calls another script by relative
  path, relocated; verifies the launcher chain works after moving.
- **`relocation-elf`** — a real dynamic ELF binary (GNU hello) wrapped in elf
  mode and run relocated.

## Dynamic interpreters & binaries

Real interpreters (`bash`, `perl`, `python`, …) and dynamic ELF binaries carry
two absolute `/nix/store` paths that break when moved: the ELF loader
(`PT_INTERP`) and the library search paths (`RPATH`). The launcher solves both
**in userspace, without patching any binary** by invoking `ld.so` explicitly
with a relative `--library-path`:

    <dir>/ld.so --library-path <farm> --argv0 <name> <prog> ...

This bypasses the absolute `PT_INTERP` and points `ld.so` at the libraries under
the relocated prefix. The build hook derives the **library closure
automatically** from each binary's transitive `RPATH` (no `relocLibPaths`
needed; set it only to add extra dirs).

The `example/` flake is a toolkit where a `bash` script calls another `bash`
script, a `perl` script, and a dynamic ELF (GNU hello) — all relocatable:

```sh
cd example
nix run .#prove   # copies the closure to a non-/nix prefix and runs `main` there
```

## Dependency tracking still works

Nix computes runtime dependencies by scanning outputs for the 32-char store
**hash**, not for the `/nix/store/` prefix. Our relative paths
(`../../<hash>-glibc-2.42-61/lib`) and the farm's relative symlink targets still
contain `<hash>-glibc…`, so dependencies are still detected. This is exactly the
shape [NixOS/nix#9549](https://github.com/NixOS/nix/issues/9549) wants from a
relocatable store object: references tracked by hash, no store-dir prefix. The
only requirement is keeping the full `<hash>-name` component, which we do.

## ELF binaries

Dynamic ELF binaries are wrapped in **elf mode**: the launcher runs them via
`ld.so --library-path …`, exactly like loader mode but with the binary itself
as the program. So this isn't shebang-specific — it relocates any dynamic
executable. Static ELF binaries and shared libraries are left untouched
(already relocatable / not executables).

The catch is **`/proc/self/exe`**. We `execve(ld.so, prog)`, so the kernel
records *ld.so* as the executable. Normally `/proc/self/exe` is the binary (the
kernel sets it from the main executable and loads `PT_INTERP` separately) — our
explicit-loader exec is what breaks that. The fix is always to keep the binary
as the execve'd file, which needs one of:

- an **entry-point stub** (`wrap-buddy`) — the binary stays the main executable
  and bootstraps the loader from a stub at its entry point. ELF surgery,
  **Linux-only** (Mach-O/`dyld` differ, and macOS codesigning forbids patching
  binaries; macOS also has no store-relative loader to relocate);
- a **kernel `$ORIGIN` in `PT_INTERP`** (resolve a relative loader in-kernel).

There is no unprivileged userspace way to *both* bypass the absolute `PT_INTERP`
*and* keep the binary as the execve'd file (`prctl(PR_SET_MM_EXE_FILE)` resets
across `execve`). So elf mode is safe for ELF programs that **don't** read
`/proc/self/exe`, but **breaks** ones that do to locate themselves/resources —
concretely **runc/Docker**, **Chromium/Electron**, **clang/LLVM**, **OpenJDK**,
Firefox, AppImage, PyInstaller. Those need an entry-point stub (`wrap-buddy`) or
kernel support instead. Scripts are unaffected (interpreters use `argv[0]`,
which we set via `--argv0`, so even Python's `sys.executable` stays correct).

## Scope & limits / drawbacks

- **Opacity.** The transparent `#!` line is replaced by an opaque launcher
  binary + manifest. `file`, `head -1`, package scanners, SBOM/security tooling
  and `patchShebangs --update` can no longer read the interpreter.
- **`/proc/self/exe`** in loader/elf mode points at the *loader*, not the
  program (we exec `ld.so`). Scripts are fine (they key off `argv`); ELF
  programs that read it break — see *ELF binaries*.
- **Child processes aren't covered.** If a wrapped program `exec`s another
  *dynamic* `/nix/store` binary **directly** (not via its launcher) — e.g. a
  shell calling an unwrapped `ls` — the child still has an absolute
  `PT_INTERP`/`RPATH` and breaks when relocated. Self-contained packages whose
  executables only call each other (via their launchers) are fine.
- **Library closure is auto-derived from `RPATH`**; it assumes nixpkgs-style
  absolute `RPATH`s. `dlopen` by soname is covered (the farm is consulted at
  runtime too), but `dlopen` of a hardcoded absolute `/nix/store/...` path is
  not. `relocLibPaths` can add dirs.
- **Static ELF binaries are skipped** (no `PT_INTERP`, nothing to invoke). A
  *truly* static binary is self-contained and fine. A static **glibc** binary
  that `dlopen`s NSS/iconv modules is not self-contained, but our `ld.so` trick
  can't help it (there is no `ld.so`); such binaries are already discouraged in
  Nix and would need an `LD_LIBRARY_PATH`-env wrapper instead.
- **`env -S` splitting** is not yet handled (rejected at build time).
- **`ld.so --argv0` / explicit-loader behavior** depends on a recent enough
  glibc; very old loaders lack `--argv0`.
- **Static interpreters** (e.g. `pkgsStatic.busybox`) skip the loader machinery
  entirely — they use the simpler direct mode with no loader or `relocLibPaths`.

### Notes on cost

- **Library path / `ARG_MAX`.** `ld.so --library-path` is a single argv string,
  capped at `MAX_ARG_STRLEN` (128 KiB on Linux). To stay well under it, the
  hook collapses the whole library closure into one per-output symlink farm
  (`<out>/.reloc-libs`, relative symlinks) and passes that single directory.
- **Launcher size / dedup.** Each wrapped executable gets a *copy* of the
  launcher (~65 KiB, static, stripped). It **cannot be a symlink**
  (`/proc/self/exe` would resolve it away and miss the manifest), but it **can be
  a hardlink**: the copies are byte-identical, so `nix-store --optimise`
  hardlinks them store-wide to a single inode, and ZFS/btrfs block-dedup
  collapses them too. So the on-disk cost is one inode regardless of how many are
  wrapped.

## What full store relocatability would additionally need

This tool relocates **executable entry points**. Moving a whole closure to an
arbitrary prefix and running *everything* additionally requires:

- **Relativizing absolute symlinks.** nixpkgs and Nix create absolute store
  symlinks all over (`buildEnv`/`symlinkJoin`, profiles, `result` gc-roots,
  `ln -s ${dep}/bin/x $out/bin/x`). A fixup pass can rewrite in-store targets to
  relative (`../../<hash>/bin/x`) — relocatable, and dep-tracking survives since
  the hash stays in the target. Leave targets outside the store (`/etc`, `/var`,
  dangling) alone. nixpkgs does not do this by default.
- **Rewriting store-path strings embedded in data** — `.pc`/`.la`/`.desktop`
  files, systemd units, GSettings schemas, configs, caches, and paths baked into
  binaries/scripts as data (not the shebang/RPATH).
- **The ELF `/proc/self/exe` programs** above (entry-point stub or kernel).

`/var` and `/etc` are **not** part of this: they are mutable system state that
NixOS materializes at activation, orthogonal to moving the store. Full store
relocatability is the broader [NixOS/nix#9549](https://github.com/NixOS/nix/issues/9549)
problem; this tool is one component of it.
