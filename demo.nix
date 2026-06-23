# End-to-end demo: build a package whose script shebang is replaced by the
# relocatable launcher, then it can be run from any location.
#
#   nix-build demo.nix && ./result/bin/hello
{ system ? builtins.currentSystem }:
let
  flake = builtins.getFlake (toString ./.);
  pkgs = import flake.inputs.nixpkgs { inherit system; };
  hook = flake.packages.${system}.relocatableShebangsHook;
  sh = pkgs.pkgsStatic.busybox; # static interpreter -> no loader dependency
in
pkgs.stdenv.mkDerivation {
  name = "relocatable-demo";
  dontUnpack = true;
  dontPatchShebangs = true;
  nativeBuildInputs = [ hook ];
  installPhase = ''
    mkdir -p $out/bin
    cat > $out/bin/hello <<EOF
    #!${sh}/bin/sh
    echo "hello from relocatable demo"
    echo "\$0"
    EOF
    chmod +x $out/bin/hello
    relocateShebangs $out/bin
  '';
}
