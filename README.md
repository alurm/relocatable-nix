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

The current build hook targets shebang scripts; ELF wrapping uses the identical
loader mode (see *Could this work for ELF binaries too?* — it can, with a
`/proc/self/exe` caveat).

> **Scope.** This relocates *executable entry points*. It does **not** by itself
> make a whole closure relocatable: absolute symlinks and store-path strings
> embedded in data files (`.pc`, `.desktop`, configs, caches) remain, and
> mutable system state (`/var`, `/etc`) is a separate concern nixpkgs handles at
> activation, not a store property. Full store relocatability is the broader
> problem tracked in [NixOS/nix#9549](https://github.com/NixOS/nix/issues/9549);
> this tool is one component of it, best suited to self-contained script/CLI
> packages. See *Scope & limits*.

## How it works

For each executable script, the build-time hook:

1. moves the real script aside (`bin/foo` → `bin/.foo.script`),
2. drops the launcher at the original path (`bin/foo`),
3. writes a NUL-separated manifest (`bin/.foo.reloc`) with the interpreter path
   (relative to the launcher), any interpreter args, and the relative script
   path.

The manifest keeps the launcher binary byte-for-byte identical for every script
(per-script config lives in data, not code), so the hook just copies one
prebuilt binary — no compiler, no per-script build.

At runtime the launcher reads the manifest and execs:

    <dir>/<interp-rel>  <args...>  <dir>/<script-rel>  <user args...>

No absolute paths are baked in, so the package works wherever it is extracted.

## Usage

Per-package (opt-in):

```nix
stdenv.mkDerivation {
  dontPatchShebangs = true;
  nativeBuildInputs = [ relocatable.packages.${system}.relocatableShebangsHook ];
  # the hook provides `relocateShebangs`; auto-runs in fixup, or call it:
  # postFixup = "relocateShebangs $out/bin";
}
```

Global (every package), via overlay:

```nix
nixpkgs.overlays = [ relocatable.overlays.default ];
```

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

## Dynamic interpreters

Real interpreters (`bash`, `perl`, `python`, …) are dynamically linked, so a
relocated copy has two absolute `/nix/store` paths that would break it: the
ELF loader (`PT_INTERP`) and the library search paths (`RPATH`). The launcher
solves both **in userspace, without patching any binary**, via *loader mode*:
instead of exec'ing the interpreter, it invokes the interpreter's `ld.so`
explicitly with a `--library-path` built from launcher-relative lib dirs:

    <dir>/ld.so --library-path <abs libdirs> --argv0 <interp> <interp> <script> ...

This bypasses the absolute `PT_INTERP` and points `ld.so` at the libraries under
the relocated prefix. The build hook detects a dynamic interpreter
(`patchelf --print-interpreter`) and needs the interpreter's library closure —
pass it via `relocLibPaths` (e.g. from `closureInfo`):

```nix
relocLibPaths = "$(cat ${pkgs.closureInfo { rootPaths = [ bash perl ]; }}/store-paths)";
```

The `example/` flake is a multi-script toolkit where a `bash` script calls
another `bash` script and a `perl` script — all dynamic, all relocatable:

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

## Could this work for ELF binaries too?

Yes — loader mode is really "run PROGRAM via `ld.so --library-path …`", which is
exactly how you run a relocated dynamic *ELF* binary (PROGRAM = the binary, no
trailing script). So the launcher generalizes beyond shebangs to any dynamic
executable with almost no new logic; shebangs are just one case.

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
across `execve`). So this shim is the right tool for **scripts** (interpreters
use `argv[0]`, which we set via `--argv0`, so even Python's `sys.executable`
stays correct) and for ELF programs that don't read `/proc/self/exe`; for
arbitrary binaries — e.g. **runc/Docker**, **Chromium/Electron**, **clang/LLVM**,
**OpenJDK** — an entry-point stub or kernel support is required.

## Scope & limits / drawbacks

- **Opacity.** The transparent `#!` line is replaced by an opaque launcher
  binary + manifest. `file`, `head -1`, package scanners, SBOM/security tooling
  and `patchShebangs --update` can no longer read the interpreter.
- **`$0` / `/proc/self/exe` shift.** The script sees a constructed `$0`, and in
  loader mode `/proc/self/exe` inside the interpreter is the *loader*, not the
  script. Fine for shells/perl/python (they key off `argv`), but software that
  introspects its own path can be surprised.
- **Child processes aren't covered.** Loader mode fixes the launched
  interpreter, but if that interpreter `exec`s another *dynamic* `/nix/store`
  binary directly (e.g. a shell calling `ls`), the child still has an absolute
  `PT_INTERP`/`RPATH` and breaks when relocated. Self-contained packages whose
  scripts only call each other (via their launchers) are fine; calling arbitrary
  dynamic store binaries is not.
- **`relocLibPaths` is required for dynamic interpreters** and must contain the
  full library closure; a missing lib surfaces only at runtime.
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
- **Launcher size / dedup.** Each wrapped script gets a *copy* of the launcher
  (~65 KiB, static, stripped). It **cannot be a symlink** (`/proc/self/exe`
  would resolve it away and miss the manifest), but it **can be a hardlink**:
  the copies are byte-identical, so `nix-store --optimise` hardlinks them
  store-wide to a single inode, and ZFS/btrfs block-dedup collapses them too.
  So the on-disk cost is one inode regardless of script count. Still, the
  per-script copy + manifest makes this a per-package, opt-in tool rather than a
  nixpkgs-wide default.

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
