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

          # Base hook providing `relocateExecutables` (alias `relocateShebangs`).
          relocatableShebangsHook = pkgs.makeSetupHook
            {
              name = "relocatable-shebangs-hook";
              propagatedBuildInputs = [ pkgs.patchelf ];
            }
            (pkgs.writeText "relocate-shebangs-setup.sh" ''
              relocatableLauncher="${launcher}/bin/launcher"
              source ${./relocate-shebangs.sh}
            '');

          # Auto-wrapping variant: registers a fixup hook that relocates every
          # output's bin/. This is what the overlay uses to "wrap everything";
          # opt out per-derivation with `dontRelocate = true`.
          relocatableAutoHook = pkgs.makeSetupHook
            {
              name = "relocatable-auto-hook";
              propagatedBuildInputs = [ relocatableShebangsHook ];
            }
            (pkgs.writeText "relocate-auto-setup.sh" ''
              _relocateAuto() {
                # Runs after patchShebangs (appended later to fixupOutputHooks).
                if [[ -z "''${dontRelocate-}" && -e "''${prefix:-}" ]]; then
                  relocateExecutables "$prefix"
                fi
              }
              fixupOutputHooks+=(_relocateAuto)
            '');

          suite = import ./checks.nix {
            inherit pkgs lib launcher;
            hook = relocatableShebangsHook;
          };
        in
        {
          packages = suite.packages // {
            inherit launcher relocatableShebangsHook relocatableAutoHook;
            default = launcher;
          };
          checks = suite.checks;
          devShells.default = pkgs.mkShell { packages = [ pkgs.gcc ]; };
        };

      forAll = lib.genAttrs systems perSystem;
    in
    {
      packages = lib.mapAttrs (_: v: v.packages) forAll;
      checks = lib.mapAttrs (_: v: v.checks) forAll;
      devShells = lib.mapAttrs (_: v: v.devShells) forAll;

      # Inject the auto-wrapping hook into every package's fixup phase, so every
      # output's bin/ is relocated. Opt out per-derivation with
      # `dontRelocate = true`. (See the warning in the README before enabling
      # this globally — it wraps build-time tools too.)
      overlays.default = final: prev: {
        stdenv = prev.stdenv.override (old: {
          extraNativeBuildInputs = (old.extraNativeBuildInputs or [ ])
            ++ [ self.packages.${prev.stdenv.hostPlatform.system}.relocatableAutoHook ];
        });
      };
    };
}
