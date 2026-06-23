{
  description = "Example consumer of relocatable-nix: a relocatable script package";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.relocatable-nix.url = "path:..";
  inputs.relocatable-nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, relocatable-nix }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hook = relocatable-nix.packages.${system}.relocatableShebangsHook;

      # A statically-linked interpreter keeps the whole package relocatable
      # end-to-end (no ld.so dependency to chase).
      sh = pkgs.pkgsStatic.busybox;

      greet = pkgs.stdenv.mkDerivation {
        name = "greet";
        dontUnpack = true;
        dontPatchShebangs = true;
        nativeBuildInputs = [ hook ];
        installPhase = ''
          mkdir -p $out/bin
          cat > $out/bin/greet <<EOF
          #!${sh}/bin/sh
          echo "greetings from a relocatable package"
          echo "I am: \$0"
          echo "store prefix does not matter"
          EOF
          chmod +x $out/bin/greet
          relocateShebangs $out/bin
        '';
      };
    in
    {
      packages.${system}.default = greet;

      # `nix run .#prove` builds greet, copies its closure to a NON-/nix prefix,
      # and runs it there to demonstrate relocatability.
      apps.${system}.prove = {
        type = "app";
        program = toString (pkgs.writeShellScript "prove-relocatable" ''
          set -e
          export PATH=${pkgs.coreutils}/bin:$PATH
          out=${greet}
          dest=$(mktemp -d)/relocated-store
          mkdir -p "$dest"
          echo "Copying closure to non-/nix prefix: $dest"
          for p in $(${pkgs.nix}/bin/nix-store -qR "$out"); do
            cp -r "$p" "$dest/$(basename "$p")"
            chmod -R u+w "$dest/$(basename "$p")"
          done
          echo
          echo "Running relocated copy (note: path is $dest, not /nix/store):"
          "$dest/$(basename "$out")/bin/greet"
        '');
      };
    };
}
