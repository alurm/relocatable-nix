# Build-time hook: replace script shebangs with the relocatable launcher.
#
# Derived from nixpkgs' patchShebangs (the shebang-parsing half is the same);
# the difference is the output. For each executable script we
#
#   1. move the real script aside (to <dir>/.<name>.script),
#   2. drop a copy of the launcher at the original path,
#   3. write a NUL-separated launch manifest (<dir>/.<name>.reloc) describing
#      how to run it. The manifest keeps the launcher binary identical for every
#      script (config travels as data), so the hook needs no per-script build.
#
# Two interpreter cases are handled:
#
#   * static interpreter (no ELF loader): "direct" manifest, the launcher execs
#     the interpreter directly.
#
#   * dynamically-linked interpreter (bash/perl/python/...): "loader" manifest,
#     the launcher invokes the interpreter's ld.so explicitly with a
#     --library-path, so the interpreter is relocatable without patching any
#     binary. The libraries are collapsed into one per-output symlink farm
#     (<out>/.reloc-libs) of relative symlinks, so --library-path is a single
#     short entry (avoids the per-arg ARG_MAX limit). This needs the library
#     closure: set $relocLibPaths to a whitespace-separated list of store paths
#     whose lib/ dirs should be searched (e.g. from `closureInfo`).
#
# Usage:
#   dontPatchShebangs = true;
#   nativeBuildInputs = [ relocatableShebangsHook ];
#   relocLibPaths = "${lib.concatStringsSep " " closurePaths}";   # for dynamic
#   postFixup = "relocateShebangs $out/bin";

# Populate $1 with relative symlinks to every library in $relocLibPaths, so a
# single directory serves as the whole --library-path.
_relocLibFarm() {
    local farm="$1" p d so name
    mkdir -p "$farm"
    for p in ${relocLibPaths:-}; do
        for d in lib lib64; do
            [[ -d "$p/$d" ]] || continue
            for so in "$p/$d"/*; do
                [[ -f "$so" ]] || continue          # regular files only
                name="$(basename "$so")"
                [[ -e "$farm/$name" ]] && continue  # first wins on collision
                ln -rs "$so" "$farm/$name"          # relative symlink
            done
        done
    done
}

relocateShebangs() {
    local farm=""   # built lazily on the first dynamic interpreter

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

        local interpRel scriptDest manifest
        interpRel="$(realpath --no-symlinks --relative-to="$dir" "$newPath")"
        scriptDest=".$base.script"
        manifest="$dir/.$base.reloc"

        # Is the interpreter dynamically linked? (patchelf prints its loader.)
        local loaderAbs=""
        loaderAbs="$(patchelf --print-interpreter "$newPath" 2>/dev/null || true)"

        mv "$f" "$dir/$scriptDest"
        cp "$relocatableLauncher" "$f"
        chmod +x "$f"

        if [[ -n "$loaderAbs" ]]; then
            # Dynamic interpreter -> loader-mode manifest.
            if [[ -z "${relocLibPaths:-}" ]]; then
                echo "$f: dynamic interpreter $newPath but \$relocLibPaths is empty" >&2
                exit 1
            fi
            if [[ -z "$farm" ]]; then
                farm="${out:-$(dirname "$dir")}/.reloc-libs"
                _relocLibFarm "$farm"
            fi

            local loaderRel libdirsRel
            loaderRel="$(realpath --no-symlinks --relative-to="$dir" "$loaderAbs")"
            libdirsRel="$(realpath --no-symlinks --relative-to="$dir" "$farm")"

            {
                printf 'l\0%s\0%s\0%s\0' "$loaderRel" "$libdirsRel" "$interpRel"
                for a in "${interpArgs[@]}"; do [[ -n "$a" ]] && printf '%s\0' "$a"; done
                printf '%s\0' "$scriptDest"
            } > "$manifest"
            echo "$f: loader-mode launcher -> $interpRel via $loaderRel"
        else
            # Static interpreter -> direct-mode manifest.
            {
                printf 'd\0%s\0' "$interpRel"
                for a in "${interpArgs[@]}"; do [[ -n "$a" ]] && printf '%s\0' "$a"; done
                printf '%s\0' "$scriptDest"
            } > "$manifest"
            echo "$f: direct-mode launcher -> $interpRel"
        fi
    done < <(find "$@" -type f -perm -0100 -print0)
}
