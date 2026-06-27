# Demo packages and the test suite, factored out of flake.nix.
# Returns { packages = { demo* }; checks = { ... }; }.
{ pkgs, lib, launcher, hook, autoHook }:
let
  mkDemo = name: install: pkgs.stdenv.mkDerivation {
    inherit name;
    dontUnpack = true;
    dontPatchShebangs = true;          # demos hardcode absolute interpreters
    nativeBuildInputs = [ hook ];
    installPhase = install + "\nrelocateExecutables $out/bin\n";
  };

  # Built like a real package would be under the overlay: the auto hook wraps
  # everything in fixup, patchShebangs runs (NOT disabled), and the script uses
  # a raw `#!/usr/bin/env` line — so this exercises env normalization + the
  # auto-wrap path (the same mechanism overlays.default registers) without a
  # stdenv rebuild. No explicit relocateExecutables call.
  demoAuto = pkgs.stdenv.mkDerivation {
    name = "relocatable-demo-auto";
    dontUnpack = true;
    nativeBuildInputs = [ autoHook ];
    installPhase = ''
      mkdir -p $out/bin
      cat > $out/bin/auto <<'EOF'
      #!/usr/bin/env bash
      echo "auto-ok $BASH_VERSION"
      EOF
      chmod +x $out/bin/auto
    '';
  };

  demo = mkDemo "relocatable-demo" ''
    mkdir -p $out/bin
    cat > $out/bin/hello <<EOF
    #!${pkgs.pkgsStatic.busybox}/bin/sh
    echo "hello from relocatable demo"
    echo "argv0=\$0"
    EOF
    chmod +x $out/bin/hello
  '';

  demoDynamic = mkDemo "relocatable-demo-dynamic" ''
    mkdir -p $out/bin
    cat > $out/bin/hi <<EOF
    #!${pkgs.bash}/bin/bash
    echo "dyn hello \$BASH_VERSION"
    EOF
    chmod +x $out/bin/hi
  '';

  demoElf = mkDemo "relocatable-demo-elf" ''
    mkdir -p $out/bin
    cp ${pkgs.hello}/bin/hello $out/bin/hello
    chmod +w $out/bin/hello
  '';

  demoInterScript = mkDemo "relocatable-demo-interscript" ''
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
  '';

  # Copy a package's closure to a non-/nix prefix, run one of its binaries
  # there, and assert each needle appears in the output.
  mkRelocCheck = { name, drv, bin, needles }:
    pkgs.runCommand name { exportReferencesGraph = [ "closure" drv ]; } (''
      reloc=$TMPDIR/relocated-store
      mkdir -p $reloc
      for p in $(grep -E '^/nix/store/' closure | sort -u); do
        cp -r "$p" "$reloc/$(basename "$p")"
        chmod -R u+w "$reloc/$(basename "$p")"
      done
      got=$("$reloc/$(basename ${drv})/bin/${bin}")
      echo "$got"
    '' + lib.concatMapStrings
      (n: ''echo "$got" | grep -qF ${lib.escapeShellArg n} || { echo "FAIL: missing: ${n}"; exit 1; }
'')
      needles + ''
      touch $out
    '');

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

    mv $root $TMPDIR/moved
    got2=$($TMPDIR/moved/bin/hello x) || true
    echo "$got2" | grep -q '^unit-ok ' || { echo "FAIL: relocated"; exit 1; }

    install -m755 ${launcher}/bin/launcher $TMPDIR/orphan
    if $TMPDIR/orphan 2>/dev/null; then
      echo "FAIL: orphan launcher should error without a manifest"; exit 1
    fi
    touch $out
  '';
in
{
  packages = { inherit demo demoDynamic demoElf demoAuto; };
  checks = {
    launcher-unit = launcherUnitTest;
    relocation = mkRelocCheck {
      name = "test-relocation"; drv = demo; bin = "hello";
      needles = [ "hello from relocatable demo" "relocated-store/" ];
    };
    relocation-dynamic = mkRelocCheck {
      name = "test-relocation-dynamic"; drv = demoDynamic; bin = "hi";
      needles = [ "dyn hello" ];
    };
    relocation-interscript = mkRelocCheck {
      name = "test-relocation-interscript"; drv = demoInterScript; bin = "outer";
      needles = [ "outer-start" "inner-ran" "outer-end" ];
    };
    relocation-elf = mkRelocCheck {
      name = "test-relocation-elf"; drv = demoElf; bin = "hello";
      needles = [ "Hello, world!" ];
    };
    # Auto-hook path (overlay mechanism): a raw env shebang, normalized by
    # patchShebangs and auto-wrapped in fixup, then run relocated.
    relocation-auto = mkRelocCheck {
      name = "test-relocation-auto"; drv = demoAuto; bin = "auto";
      needles = [ "auto-ok" ];
    };
  };
}
