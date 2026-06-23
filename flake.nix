{
  description = "Relocatable Nix packages via self-locating shebang launchers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # The self-locating launcher binary.
      packages = forAll (pkgs: rec {
        launcher =
          let
            # Static on Linux (musl) so the launcher itself has no loader
            # dependency; plain on Darwin (links libSystem, always present).
            buildStdenv = if pkgs.stdenv.isLinux then pkgs.pkgsStatic.stdenv else pkgs.stdenv;
          in
          buildStdenv.mkDerivation {
            name = "relocatable-nix-launcher";
            src = ./launcher.c;
            dontUnpack = true;
            buildPhase = ''
              $CC -O2 -Wall -o launcher $src
            '';
            installPhase = ''
              mkdir -p $out/bin
              install -m555 launcher $out/bin/launcher
            '';
          };

        # Setup hook: provides relocateShebangs and points it at the launcher.
        relocatableShebangsHook = pkgs.makeSetupHook
          {
            name = "relocatable-shebangs-hook";
            substitutions = { launcher = "${launcher}/bin/launcher"; };
          }
          (pkgs.writeText "relocate-shebangs-setup.sh" ''
            relocatableLauncher="@launcher@"
            source ${./relocate-shebangs.sh}
          '');

        default = launcher;
      });

      # Overlay: inject the hook into every package's fixup phase.
      overlays.default = final: prev: {
        stdenv = prev.stdenv.override (old: {
          extraNativeBuildInputs = (old.extraNativeBuildInputs or [ ])
            ++ [ self.packages.${prev.stdenv.hostPlatform.system}.relocatableShebangsHook ];
        });
      };

      devShells = forAll (pkgs: {
        default = pkgs.mkShell { packages = [ pkgs.gcc ]; };
      });
    };
}
