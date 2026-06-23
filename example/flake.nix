{
  description = "Relocatable multi-script toolkit using dynamic interpreters (bash + perl)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.relocatable-nix.url = "path:..";
  inputs.relocatable-nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, relocatable-nix }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hook = relocatable-nix.packages.${system}.relocatableShebangsHook;

      bash = pkgs.bash;
      perl = pkgs.perl;

      # Full runtime closure of the interpreters -> the library search path the
      # launcher needs to run them relocated.
      closure = pkgs.closureInfo { rootPaths = [ bash perl ]; };

      toolkit = pkgs.stdenv.mkDerivation {
        name = "relocatable-toolkit";
        dontUnpack = true;
        dontPatchShebangs = true;
        nativeBuildInputs = [ hook ];
        installPhase = ''
          mkdir -p $out/bin

          # 1) a bash script
          cat > $out/bin/greet <<EOF
          #!${bash}/bin/bash
          echo "[greet] hello from bash \$BASH_VERSION"
          EOF

          # 2) a perl script
          cat > $out/bin/report <<EOF
          #!${perl}/bin/perl
          use strict; use warnings;
          printf "[report] perl %vd computed 7 * 6 = %d\n", \$^V, 7 * 6;
          EOF

          # 3) a bash script that calls the other two by path relative to itself.
          # Shebang is interpolated; the body is a quoted heredoc kept literal.
          echo "#!${bash}/bin/bash" > $out/bin/main
          cat >> $out/bin/main <<'EOF'
          here="$(dirname "$0")"
          echo "[main] running toolkit from: $here"
          "$here/greet"
          "$here/report"
          echo "[main] done"
          EOF

          chmod +x $out/bin/greet $out/bin/report $out/bin/main

          # dynamic interpreters: give the hook the library closure
          export relocLibPaths="$(cat ${closure}/store-paths)"
          relocateShebangs $out/bin
        '';
      };
    in
    {
      packages.${system}.default = toolkit;

      # `nix run .#prove` copies the closure to a NON-/nix prefix and runs `main`
      # there, exercising both dynamic interpreters relocated.
      apps.${system}.prove = {
        type = "app";
        program = toString (pkgs.writeShellScript "prove-toolkit" ''
          set -e
          export PATH=${pkgs.coreutils}/bin:${pkgs.nix}/bin:$PATH
          out=${toolkit}
          dest=$(mktemp -d)/relocated-store
          mkdir -p "$dest"
          echo "Copying closure to non-/nix prefix: $dest"
          for p in $(nix-store -qR "$out"); do
            cp -r "$p" "$dest/$(basename "$p")"
            chmod -R u+w "$dest/$(basename "$p")"
          done
          echo
          echo "=== running relocated toolkit (prefix: $dest) ==="
          "$dest/$(basename "$out")/bin/main"
        '');
      };
    };
}
