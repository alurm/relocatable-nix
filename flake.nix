{
  description = "Relocatable Nix executables (scripts and dynamic ELF) via self-locating launchers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # The self-locating launcher. Static on Linux (musl) so it has no
          # loader dependency of its own; plain on Darwin (libSystem is always
          # present).
          launcher =
            let
              buildStdenv = if pkgs.stdenv.isLinux then pkgs.pkgsStatic.stdenv else pkgs.stdenv;
            in
            buildStdenv.mkDerivation {
              name = "relocatable-nix-launcher";
              # Compile a single source file directly. Avoid the unpack/install
              # phases (and $src) so the build is robust across store backends
              # (e.g. `--store ./s`) and writes only to $out.
              dontUnpack = true;
              dontFixup = true;
              buildCommand = ''
                mkdir -p "$out/bin"
                $CC -Os -Wall -o "$out/bin/launcher" ${./launcher.c}
                $STRIP --strip-all "$out/bin/launcher" 2>/dev/null || true
                chmod 555 "$out/bin/launcher"
              '';
            };

          # Base hook providing relocateExecutables.
          relocatableHook = pkgs.makeSetupHook
            {
              name = "relocatable-hook";
              propagatedBuildInputs = [ pkgs.patchelf ];
            }
            (pkgs.writeText "relocate-setup.sh" ''
              relocatableLauncher="${launcher}/bin/launcher"
              source ${./relocate-executables.sh}
            '');

          # Auto-wrapping variant: registers a fixup hook that relocates every
          # output's bin/. This is what the overlay uses to "wrap everything";
          # opt out per-derivation with `dontRelocate = true`.
          relocatableAutoHook = pkgs.makeSetupHook
            {
              name = "relocatable-auto-hook";
              propagatedBuildInputs = [ relocatableHook ];
            }
            (pkgs.writeText "relocate-auto-setup.sh" ''
              _relocateAuto() {
                if [[ -n "''${dontRelocate-}" || ! -e "''${prefix:-}" ]]; then
                  return 0
                fi
                # Normalize shebangs first, independent of fixupOutputHooks
                # ordering: patchShebangs is idempotent (store-path shebangs are
                # skipped), so calling it here is safe whether or not it already
                # ran, and ensures relocateExecutables never sees a raw env line.
                if declare -F patchShebangsAuto >/dev/null; then
                  patchShebangsAuto
                fi
                relocateExecutables "$prefix"
              }
              fixupOutputHooks+=(_relocateAuto)
            '');

          # Wrap an ALREADY-BUILT package: copy its tree and relocate it, with no
          # rebuild and without touching build-time tools. This is the cheap,
          # reliable way to relocate a package (vs. the overlay, which rebuilds
          # via stdenv and wraps the toolchain — see README).
          makeRelocatable = drv: pkgs.runCommand "${drv.name}-relocatable"
            { nativeBuildInputs = [ relocatableHook ]; }
            ''
              cp -r ${drv} $out
              chmod -R u+w $out
              relocateExecutables $out
            '';

          # Rebuild a package with the auto hook in its fixup: only this package
          # rebuilds, its build inputs stay unwrapped. Used by overlays.default.
          wrap = drv: drv.overrideAttrs (o: {
            nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [ relocatableAutoHook ];
          });

          # nixpkgs with our overlay applied — only used for the eval-level
          # overlay-wired check (building through it rebuilds the toolchain).
          overlayPkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };

          suite = import ./checks.nix {
            inherit pkgs lib launcher;
            hook = relocatableHook;
            autoHook = relocatableAutoHook;
            overlayHello = overlayPkgs.hello;
            relocatableHello = makeRelocatable pkgs.hello;
          };
        in
        {
          packages = suite.packages // {
            inherit launcher relocatableHook relocatableAutoHook;
            # GNU hello relocated by wrapping the prebuilt package (no rebuild).
            helloRelocatable = makeRelocatable pkgs.hello;
            default = launcher;
          };
          checks = suite.checks;
          devShells.default = pkgs.mkShell { packages = [ pkgs.gcc ]; };
          inherit makeRelocatable wrap;
        };

      forAll = lib.genAttrs systems perSystem;
    in
    {
      packages = lib.mapAttrs (_: v: v.packages) forAll;
      checks = lib.mapAttrs (_: v: v.checks) forAll;
      devShells = lib.mapAttrs (_: v: v.devShells) forAll;

      # Wrap selected packages' outputs. Each listed package is rebuilt with the
      # auto hook in its fixup — so only THAT package rebuilds and its build
      # inputs stay unwrapped (the toolchain is untouched, unlike a stdenv
      # override). Extend the list, or use `lib.<sys>.makeRelocatable` /
      # `lib.<sys>.relocateOverlay` for arbitrary packages.
      #
      # Note: do not wrap packages used as build tools that read /proc/self/exe
      # (bison, clang, …) — they'd break when run. See the README.
      overlays.default = final: prev:
        let wrap = self.lib.${prev.stdenv.hostPlatform.system}.wrap;
        in { hello = wrap prev.hello; };

      lib = lib.mapAttrs
        (system: v: {
          inherit (v) makeRelocatable wrap;
          # relocateOverlay [ "foo" "bar" ] -> an overlay wrapping those outputs.
          relocateOverlay = names: _final: prev:
            lib.genAttrs names (n: v.wrap prev.${n});
        })
        forAll;
    };
}
