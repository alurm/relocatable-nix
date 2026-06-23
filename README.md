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
3. writes a NUL-separated sidecar (`bin/foo.rb`) with the interpreter path
   (relative to the launcher), any interpreter args, and the relative script
   path.

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
nix-build demo.nix            # a demo package built through the hook
./result/bin/hello            # runs in place
# copy the closure to a different prefix and it still runs
```

## Scope & limits

- **Scripts**: fully handled.
- **Libraries**: use RPATH `$ORIGIN` (already supported by `ld.so`).
- **Dynamically-linked interpreters' loader** (`ld.so` via `PT_INTERP`): *not*
  solved here — that's the one piece needing the kernel, `wrap-buddy`, or a
  static interpreter. With a static interpreter (e.g. `pkgsStatic.busybox`) the
  package is relocatable end-to-end with no extra work.
- `env -S` argument splitting is not yet handled (rejected at build time).
- Wrapping changes `$0`/`/proc/self/exe` semantics slightly and replaces the
  transparent `#!` line with an opaque binary — a deliberate tradeoff for
  portability without kernel support.
