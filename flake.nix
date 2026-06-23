{
  description = "Relocatable Nix packages via self-locating shebang launchers";

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
              src = ./launcher.c;
              dontUnpack = true;
              buildPhase = "$CC -O2 -Wall -o launcher $src";
              installPhase = "install -Dm555 launcher $out/bin/launcher";
            };

          # Setup hook providing `relocateShebangs`, pointed at the launcher.
          relocatableShebangsHook = pkgs.makeSetupHook
            {
              name = "relocatable-shebangs-hook";
            }
            (pkgs.writeText "relocate-shebangs-setup.sh" ''
              relocatableLauncher="${launcher}/bin/launcher"
              source ${./relocate-shebangs.sh}
            '');

          # A package built through the hook, used by both `packages.demo` and
          # the relocation test. Uses a static interpreter so it is relocatable
          # end-to-end (no ld.so to chase).
          demo = pkgs.stdenv.mkDerivation {
            name = "relocatable-demo";
            dontUnpack = true;
            dontPatchShebangs = true;
            nativeBuildInputs = [ relocatableShebangsHook ];
            installPhase = ''
              mkdir -p $out/bin
              cat > $out/bin/hello <<EOF
              #!${pkgs.pkgsStatic.busybox}/bin/sh
              echo "hello from relocatable demo"
              echo "argv0=\$0"
              EOF
              chmod +x $out/bin/hello
              relocateShebangs $out/bin
            '';
          };

          # Test: launcher in isolation, with a hand-built layout and sidecar,
          # then moved to prove relocation.
          launcherUnitTest = pkgs.runCommand "test-launcher-unit" { } ''
            root=$TMPDIR/pkg
            mkdir -p $root/bin $root/libexec $root/sh/bin
            install -m755 ${launcher}/bin/launcher $root/bin/hello
            install -m755 ${pkgs.pkgsStatic.busybox}/bin/busybox $root/sh/bin/sh
            cat > $root/libexec/hello.sh <<'EOS'
            echo "unit-ok $0 $*"
            EOS
            chmod +x $root/libexec/hello.sh
            printf '../sh/bin/sh\0../libexec/hello.sh\0' > $root/bin/hello.rb

            got=$($root/bin/hello a b)
            echo "in place: $got"
            echo "$got" | grep -q '^unit-ok ' || { echo "FAIL: bad output"; exit 1; }
            case "$got" in *" a b") ;; *) echo "FAIL: args not forwarded"; exit 1;; esac

            # Move the whole tree and re-run: must still work (relocatable).
            mv $root $TMPDIR/moved
            got2=$($TMPDIR/moved/bin/hello x)
            echo "relocated: $got2"
            echo "$got2" | grep -q '^unit-ok ' || { echo "FAIL: relocated"; exit 1; }
            touch $out
          '';

          # Test: a hook-built package, copied to a NON-/nix prefix and run there.
          relocationTest = pkgs.runCommand "test-relocation"
            {
              exportReferencesGraph = [ "closure" demo ];
            } ''
            reloc=$TMPDIR/relocated-store
            mkdir -p $reloc
            for p in $(grep -E '^/nix/store/' closure | sort -u); do
              cp -r "$p" "$reloc/$(basename "$p")"
              chmod -R u+w "$reloc/$(basename "$p")"
            done

            name=$(basename ${demo})
            echo "running from non-/nix prefix: $reloc/$name"
            got=$("$reloc/$name/bin/hello")
            echo "$got"
            echo "$got" | grep -q 'hello from relocatable demo' \
              || { echo "FAIL: relocated package did not run"; exit 1; }
            echo "$got" | grep -q "argv0=$reloc/" \
              || { echo "FAIL: argv0 not resolved under relocated prefix"; exit 1; }
            touch $out
          '';
        in
        {
          packages = { inherit launcher relocatableShebangsHook demo; default = launcher; };
          checks = { launcher-unit = launcherUnitTest; relocation = relocationTest; };
          devShells.default = pkgs.mkShell { packages = [ pkgs.gcc ]; };
        };

      forAll = lib.genAttrs systems perSystem;
    in
    {
      packages = lib.mapAttrs (_: v: v.packages) forAll;
      checks = lib.mapAttrs (_: v: v.checks) forAll;
      devShells = lib.mapAttrs (_: v: v.devShells) forAll;

      # Inject the hook into every package's fixup phase.
      overlays.default = final: prev: {
        stdenv = prev.stdenv.override (old: {
          extraNativeBuildInputs = (old.extraNativeBuildInputs or [ ])
            ++ [ self.packages.${prev.stdenv.hostPlatform.system}.relocatableShebangsHook ];
        });
      };
    };
}
