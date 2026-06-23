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

          # Setup hook providing `relocateShebangs`, pointed at the launcher.
          relocatableShebangsHook = pkgs.makeSetupHook
            {
              name = "relocatable-shebangs-hook";
              propagatedBuildInputs = [ pkgs.patchelf ];
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

          # A package using a *dynamic* interpreter (bash), made relocatable via
          # loader-mode launchers. Exercised by the dynamic relocation test.
          demoDynamic = pkgs.stdenv.mkDerivation {
            name = "relocatable-demo-dynamic";
            dontUnpack = true;
            dontPatchShebangs = true;
            nativeBuildInputs = [ relocatableShebangsHook ];
            installPhase = ''
              mkdir -p $out/bin
              cat > $out/bin/hi <<EOF
              #!${pkgs.bash}/bin/bash
              echo "dyn hello \$BASH_VERSION"
              EOF
              chmod +x $out/bin/hi
              export relocLibPaths="$(cat ${pkgs.closureInfo { rootPaths = [ pkgs.bash ]; }}/store-paths)"
              relocateShebangs $out/bin
            '';
          };

          # A two-script dynamic package where one launcher-wrapped script calls
          # another by a path relative to itself — the supported inter-script
          # case. Exercised relocated by relocationInterScriptTest.
          demoInterScript = pkgs.stdenv.mkDerivation {
            name = "relocatable-demo-interscript";
            dontUnpack = true;
            dontPatchShebangs = true;
            nativeBuildInputs = [ relocatableShebangsHook ];
            installPhase = ''
              mkdir -p $out/bin
              cat > $out/bin/inner <<EOF
              #!${pkgs.bash}/bin/bash
              echo "inner-ran"
              EOF
              cat > $out/bin/outer <<EOF
              #!${pkgs.bash}/bin/bash
              echo "outer-start"
              "\$(dirname "\$0")/inner"
              echo "outer-end"
              EOF
              chmod +x $out/bin/inner $out/bin/outer
              export relocLibPaths="$(cat ${pkgs.closureInfo { rootPaths = [ pkgs.bash ]; }}/store-paths)"
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
            exit 7
            EOS
            chmod +x $root/libexec/hello.sh
            printf 'd\0../sh/bin/sh\0../libexec/hello.sh\0' > $root/bin/.hello.reloc

            rc=0
            got=$($root/bin/hello a b) || rc=$?
            echo "in place: $got (rc=$rc)"
            echo "$got" | grep -q '^unit-ok ' || { echo "FAIL: bad output"; exit 1; }
            case "$got" in *" a b") ;; *) echo "FAIL: args not forwarded"; exit 1;; esac
            [ "$rc" = 7 ] || { echo "FAIL: exit code not propagated (got $rc)"; exit 1; }

            # Move the whole tree and re-run: must still work (relocatable).
            mv $root $TMPDIR/moved
            got2=$($TMPDIR/moved/bin/hello x) || true
            echo "relocated: $got2"
            echo "$got2" | grep -q '^unit-ok ' || { echo "FAIL: relocated"; exit 1; }

            # Missing sidecar must fail cleanly (non-zero), not crash.
            install -m755 ${launcher}/bin/launcher $TMPDIR/orphan
            if $TMPDIR/orphan 2>/dev/null; then
              echo "FAIL: orphan launcher should error without a sidecar"; exit 1
            fi
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

          # Test: a dynamic-interpreter package, copied to a non-/nix prefix and
          # run there (loader-mode launcher invoking ld.so --library-path).
          relocationDynamicTest = pkgs.runCommand "test-relocation-dynamic"
            {
              exportReferencesGraph = [ "closure" demoDynamic ];
            } ''
            reloc=$TMPDIR/relocated-store
            mkdir -p $reloc
            for p in $(grep -E '^/nix/store/' closure | sort -u); do
              cp -r "$p" "$reloc/$(basename "$p")"
              chmod -R u+w "$reloc/$(basename "$p")"
            done
            name=$(basename ${demoDynamic})
            got=$("$reloc/$name/bin/hi")
            echo "$got"
            echo "$got" | grep -q 'dyn hello' \
              || { echo "FAIL: relocated dynamic package did not run"; exit 1; }
            touch $out
          '';

          # Test: relocated package where one script calls another by relative
          # path — both go through launchers, so the chain works after moving.
          relocationInterScriptTest = pkgs.runCommand "test-relocation-interscript"
            {
              exportReferencesGraph = [ "closure" demoInterScript ];
            } ''
            reloc=$TMPDIR/relocated-store
            mkdir -p $reloc
            for p in $(grep -E '^/nix/store/' closure | sort -u); do
              cp -r "$p" "$reloc/$(basename "$p")"
              chmod -R u+w "$reloc/$(basename "$p")"
            done
            name=$(basename ${demoInterScript})
            got=$("$reloc/$name/bin/outer")
            echo "$got"
            echo "$got" | grep -q 'outer-start' || { echo "FAIL: outer"; exit 1; }
            echo "$got" | grep -q 'inner-ran'   || { echo "FAIL: inner not called"; exit 1; }
            echo "$got" | grep -q 'outer-end'   || { echo "FAIL: outer-end"; exit 1; }
            touch $out
          '';
        in
        {
          packages = { inherit launcher relocatableShebangsHook demo demoDynamic; default = launcher; };
          checks = {
            launcher-unit = launcherUnitTest;
            relocation = relocationTest;
            relocation-dynamic = relocationDynamicTest;
            relocation-interscript = relocationInterScriptTest;
          };
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
