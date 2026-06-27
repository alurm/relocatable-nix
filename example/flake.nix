{
  description = "Relocatable toolkit: dynamic bash + perl scripts and a dynamic ELF binary";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.relocatable-nix.url = "path:..";
  inputs.relocatable-nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, relocatable-nix }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hook = relocatable-nix.packages.${system}.relocatableHook;

      bash = pkgs.bash;
      perl = pkgs.perl;

      # Overlay demo: wrap a stock nixpkgs package (GNU hello). Only hello
      # rebuilds; its toolchain stays unwrapped.
      overlayHello = (import nixpkgs {
        inherit system;
        overlays = [ (relocatable-nix.lib.${system}.relocateOverlay [ "hello" ]) ];
      }).hello;

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

          # 3) a real dynamic ELF binary (GNU hello)
          cp ${pkgs.hello}/bin/hello $out/bin/hello
          chmod +w $out/bin/hello

          # 4) a bash script that calls the others by path relative to itself.
          # Shebang is interpolated; the body is a quoted heredoc kept literal.
          echo "#!${bash}/bin/bash" > $out/bin/main
          cat >> $out/bin/main <<'EOF'
          here="$(dirname "$0")"
          echo "[main] running toolkit from: $here"
          "$here/greet"
          "$here/report"
          "$here/hello"
          echo "[main] done"
          EOF

          chmod +x $out/bin/greet $out/bin/report $out/bin/main

          # Scripts AND the ELF binary are wrapped; the library closure is
          # derived automatically from each binary's RPATH.
          relocateExecutables $out/bin
        '';
      };
    in
    {
      packages.${system} = {
        default = toolkit;          # built with the per-package hook
        hello = overlayHello;       # built through the overlay
      };

      # `nix run .#prove` copies each closure to a NON-/nix prefix and runs it
      # there — proving relocation for the hook-built toolkit and the
      # overlay-built hello.
      apps.${system}.prove = {
        type = "app";
        program = toString (pkgs.writeShellScript "prove" ''
          set -e
          export PATH=${pkgs.coreutils}/bin:${pkgs.nix}/bin:$PATH
          run() { # <store-path> <relative-bin>
            local out="$1" bin="$2"
            local dest; dest="$(mktemp -d)/relocated-store"
            mkdir -p "$dest"
            for p in $(nix-store -qR "$out"); do
              cp -r "$p" "$dest/$(basename "$p")"
              chmod -R u+w "$dest/$(basename "$p")"
            done
            echo "=== running relocated from $dest ==="
            "$dest/$(basename "$out")/$bin"
          }
          run ${toolkit} bin/main
          echo
          run ${overlayHello} bin/hello
        '');
      };
    };
}
