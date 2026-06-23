# Build-time hook: replace script shebangs with the relocatable launcher.
#
# Derived from nixpkgs' patchShebangs (the shebang-parsing half is the same);
# the difference is the output. For each executable script we
#
#   1. move the real script aside (to <dir>/.<name>.script),
#   2. drop a copy of the launcher at the original path,
#   3. write a NUL-separated sidecar (<launcher>.rb) describing how to run it.
#
# Two interpreter cases are handled:
#
#   * static interpreter (no ELF loader): "direct" sidecar, the launcher execs
#     the interpreter directly.
#
#   * dynamically-linked interpreter (bash/perl/python/...): "loader" sidecar,
#     the launcher invokes the interpreter's ld.so explicitly with a
#     --library-path built from relative lib dirs, so the interpreter is
#     relocatable without patching any binary. This requires the library
#     closure: set $relocLibPaths to a whitespace-separated list of store paths
#     whose lib/ dirs should be searched (e.g. from `closureInfo`).
#
# Usage:
#   dontPatchShebangs = true;
#   nativeBuildInputs = [ relocatableShebangsHook ];
#   relocLibPaths = "${lib.concatStringsSep " " closurePaths}";   # for dynamic
#   postFixup = "relocateShebangs $out/bin";

relocateShebangs() {
    local f
    while IFS= read -r -d $'\0' f; do
        isScript "$f" || continue

        local oldInterpreterLine
        read -r oldInterpreterLine < "$f" || [ "$oldInterpreterLine" ]

        local oldPath arg0 args
        read -r oldPath arg0 args <<< "${oldInterpreterLine:2}"

        local newPath
        local interpArgs=()

        if [[ "$oldPath" == *"/bin/env" ]]; then
            if [[ $arg0 == "-"* || $arg0 == *"="* ]]; then
                echo "$f: unsupported env directive \"$oldInterpreterLine\"" >&2
                exit 1
            fi
            newPath="$(PATH="${HOST_PATH:-$PATH}" type -P "$arg0" || true)"
            read -r -a interpArgs <<< "$args"
        elif [[ "$oldPath" == /* && -x "$oldPath" ]]; then
            newPath="$oldPath"
            read -r -a interpArgs <<< "$arg0 $args"
        else
            [[ -z $oldPath ]] && oldPath="/bin/sh"
            newPath="$(PATH="${HOST_PATH:-$PATH}" type -P "$(basename "$oldPath")" || true)"
            read -r -a interpArgs <<< "$arg0 $args"
        fi

        if [[ -z "$newPath" ]]; then
            echo "$f: could not resolve interpreter for \"$oldInterpreterLine\"" >&2
            exit 1
        fi

        local dir base
        dir="$(dirname "$f")"
        base="$(basename "$f")"

        local interpRel scriptDest
        interpRel="$(realpath --no-symlinks --relative-to="$dir" "$newPath")"
        scriptDest=".$base.script"

        # Is the interpreter dynamically linked? (patchelf prints its loader.)
        local loaderAbs=""
        loaderAbs="$(patchelf --print-interpreter "$newPath" 2>/dev/null || true)"

        mv "$f" "$dir/$scriptDest"
        cp "$relocatableLauncher" "$f"
        chmod +x "$f"

        if [[ -n "$loaderAbs" ]]; then
            # Dynamic interpreter -> loader-mode sidecar.
            local loaderRel libdirsRel=""
            loaderRel="$(realpath --no-symlinks --relative-to="$dir" "$loaderAbs")"

            local p d rel
            for p in ${relocLibPaths:-}; do
                for d in lib lib64; do
                    if [[ -d "$p/$d" ]]; then
                        rel="$(realpath --no-symlinks --relative-to="$dir" "$p/$d")"
                        libdirsRel="$libdirsRel:$rel"
                    fi
                done
            done
            libdirsRel="${libdirsRel#:}"

            if [[ -z "$libdirsRel" ]]; then
                echo "$f: dynamic interpreter $newPath but \$relocLibPaths is empty" >&2
                exit 1
            fi

            {
                printf 'l\0%s\0%s\0%s\0' "$loaderRel" "$libdirsRel" "$interpRel"
                for a in "${interpArgs[@]}"; do [[ -n "$a" ]] && printf '%s\0' "$a"; done
                printf '%s\0' "$scriptDest"
            } > "$f.rb"
            echo "$f: loader-mode launcher -> $interpRel via $loaderRel"
        else
            # Static interpreter -> direct-mode sidecar.
            {
                printf 'd\0%s\0' "$interpRel"
                for a in "${interpArgs[@]}"; do [[ -n "$a" ]] && printf '%s\0' "$a"; done
                printf '%s\0' "$scriptDest"
            } > "$f.rb"
            echo "$f: direct-mode launcher -> $interpRel"
        fi
    done < <(find "$@" -type f -perm -0100 -print0)
}
