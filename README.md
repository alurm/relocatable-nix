# relocatable-nix

Make Nix packages **relocatable** — runnable from any store prefix, not just
`/nix/store` — by replacing script shebangs with a tiny self-locating launcher.

A normal shebang hardcodes an absolute interpreter path, so the package breaks
if the store moves. `relocatable-nix` replaces the script's entry point with a
small statically-linked launcher that finds itself at runtime
(`/proc/self/exe` on Linux, `_NSGetExecutablePath` on macOS) and execs the
interpreter resolved **relative to its own location** — the same idea as ELF
`$ORIGIN`, but in userspace, needing no kernel changes and no privileges.

## How it works

For each executable script, the build-time hook:

1. moves the real script aside (`bin/foo` → `bin/.foo.script`),
2. drops the launcher at the original path (`bin/foo`),
3. writes a NUL-separated sidecar (`bin/.foo.reloc`) with the interpreter path
   (relative to the launcher), any interpreter args, and the relative script
   path.

The sidecar keeps the launcher binary byte-for-byte identical for every script
(per-script config lives in data, not code), so the hook just copies one
prebuilt binary — no compiler, no per-script build.

At runtime the launcher reads the sidecar and execs:

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
nix build .#demo
nix copy --no-check-sigs --to "$PWD/s" ./result
"$PWD/s/nix/store/$(basename "$(readlink -f result)")/bin/hello"   # runs from ./s
```

- `--no-check-sigs` is required because locally-built paths are not signed by a
  trusted key.
- For a fully flattened layout (no `/nix/store` suffix at all), see the
  `example/` flake's `prove` app, which copies the closure to
  `/tmp/.../relocated-store/<hash>` and runs it there.

### Why not `nix build --store ./s`?

Building *into* an alternative store (`--store ./s`) does not work for this on a
typical setup: the build sandbox exposes the real `/nix/store` read-only, so any
output path that already exists in your real store collides and the builder
fails with `Permission denied` writing its own `$out`. This is a store/sandbox
interaction, not a property of the package. Build normally and `nix copy`
instead.

## Tests

`nix flake check` runs:

- **`launcher-unit`** — drives the launcher in isolation: argument forwarding,
  exit-code propagation, relocation (move the tree and re-run), and a clean
  error when the sidecar is missing.
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

## Scope & limits / drawbacks

- **Opacity.** The transparent `#!` line is replaced by an opaque launcher
  binary + sidecar. `file`, `head -1`, package scanners, SBOM/security tooling
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
- **`--library-path` can get long** (whole closure) and is baked into each
  sidecar; the launcher rebuilds the absolute path at exec time.
- **`env -S` splitting** is not yet handled (rejected at build time).
- **Per-program launcher binary.** Each wrapped script gets a launcher copy
  (cannot be symlinked — `/proc/self/exe` would resolve away the sidecar),
  costing space and defeating store hardlink dedup at nixpkgs scale. This makes
  it suitable as a per-package, opt-in tool, not a nixpkgs-wide default.
- **`ld.so --argv0` / explicit-loader behavior** depends on a recent enough
  glibc; very old loaders lack `--argv0`.
- **Static interpreters** (e.g. `pkgsStatic.busybox`) skip all of the above —
  they use the simpler direct mode with no loader or `relocLibPaths` needed.
