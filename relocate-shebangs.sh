# Build-time hook: make executables relocatable by replacing them with the
# self-locating launcher.
#
# Handles, in one pass over a directory:
#   * shebang scripts        -> direct mode ("d") if the interpreter is static,
#                               loader mode ("l") if it is dynamic;
#   * dynamic ELF binaries   -> elf mode ("e"), invoked via ld.so.
# Static ELF binaries and shared libraries are left alone (already relocatable
# / not executables).
#
# For each wrapped executable we:
#   1. move the real file aside (to <dir>/.<name>.real or .<name>.script),
#   2. drop a copy of the launcher at the original path,
#   3. write a NUL-separated manifest (<dir>/.<name>.reloc) describing how to
#      run it.  The launcher binary is identical for every executable; per-item
#      config travels as data, so the hook needs no per-item compilation.
#
# Dynamic executables need a library search path. We collapse the libraries into
# one per-output symlink farm (<out>/.reloc-libs, relative symlinks) so
# ld.so --library-path is a single short entry. The library set is derived
# automatically from each binary's transitive RPATH closure; set $relocLibPaths
# (whitespace-separated store paths) to add extra lib dirs if needed.
#
# Usage:
#   dontPatchShebangs = true;
#   nativeBuildInputs = [ relocatableShebangsHook ];
#   postFixup = "relocateExecutables $out/bin";   # or rely on the overlay

# Print the transitive set of RPATH lib dirs reachable from the given ELF files.
_relocLibClosure() {
    local -A seen_file=() seen_dir=()
    local -a queue=("$@")
    local f rp dir so
    while ((${#queue[@]})); do
        f="${queue[0]}"; queue=("${queue[@]:1}")
        [[ -n "${seen_file["$f"]:-}" ]] && continue
        seen_file["$f"]=1
        [[ -f "$f" ]] || continue
        rp="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
        local oldIFS="$IFS" d
        IFS=:
        local -a dirs=($rp)
        IFS="$oldIFS"
        for dir in "${dirs[@]}"; do
            [[ -d "$dir" ]] || continue
            if [[ -z "${seen_dir["$dir"]:-}" ]]; then
                seen_dir["$dir"]=1
                printf '%s\n' "$dir"
            fi
            for so in "$dir"/*.so*; do
                [[ -f "$so" ]] && queue+=("$so")
            done
        done
    done
}

relocateExecutables() {
    local farm="${out:-$(dirname "$1")}/.reloc-libs"
    declare -A _farmDirs=()   # lib dirs already merged into the farm

    # Merge the given lib dirs into the farm as relative symlinks (idempotent).
    _farmAdd() {
        local dir so name
        mkdir -p "$farm"
        for dir in "$@"; do
            [[ -n "${_farmDirs["$dir"]:-}" ]] && continue
            _farmDirs["$dir"]=1
            for so in "$dir"/*; do
                [[ -f "$so" ]] || continue
                name="$(basename "$so")"
                [[ -e "$farm/$name" ]] && continue
                ln -rs "$so" "$farm/$name"
            done
        done
    }

    # Ensure the farm covers the closure of $1 (an ELF) plus its loader's dir
    # plus any $relocLibPaths overrides, and echo the farm path relative to $2.
    _ensureFarm() {
        local elf="$1" fromDir="$2" loaderAbs p
        local -a dirs=()
        mapfile -t dirs < <(_relocLibClosure "$elf")
        loaderAbs="$(patchelf --print-interpreter "$elf" 2>/dev/null || true)"
        [[ -n "$loaderAbs" ]] && dirs+=("$(dirname "$loaderAbs")")
        for p in ${relocLibPaths:-}; do
            [[ -d "$p/lib" ]] && dirs+=("$p/lib")
            [[ -d "$p/lib64" ]] && dirs+=("$p/lib64")
        done
        _farmAdd "${dirs[@]}"
        realpath --no-symlinks --relative-to="$fromDir" "$farm"
    }

    local f
    while IFS= read -r -d $'\0' f; do
        local dir base
        dir="$(dirname "$f")"
        base="$(basename "$f")"

        # Skip our own artifacts so the pass is idempotent (.real/.script/.reloc
        # are hidden); also skips any pre-existing hidden executables.
        [[ "$base" == .* ]] && continue

        local manifest="$dir/.$base.reloc"

        if isScript "$f"; then
            # ---- shebang script ----
            local oldInterpreterLine oldPath arg0 args
            read -r oldInterpreterLine < "$f" || [ "$oldInterpreterLine" ]
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

            local interpRel scriptDest a
            interpRel="$(realpath --no-symlinks --relative-to="$dir" "$newPath")"
            scriptDest=".$base.script"

            local loaderAbs
            loaderAbs="$(patchelf --print-interpreter "$newPath" 2>/dev/null || true)"

            mv "$f" "$dir/$scriptDest"
            cp "$relocatableLauncher" "$f"; chmod +x "$f"

            if [[ -n "$loaderAbs" ]]; then
                local loaderRel libdirsRel
                loaderRel="$(realpath --no-symlinks --relative-to="$dir" "$loaderAbs")"
                libdirsRel="$(_ensureFarm "$newPath" "$dir")"
                {
                    printf 'l\0%s\0%s\0%s\0' "$loaderRel" "$libdirsRel" "$interpRel"
                    for a in "${interpArgs[@]}"; do [[ -n "$a" ]] && printf '%s\0' "$a"; done
                    printf '%s\0' "$scriptDest"
                } > "$manifest"
                echo "$f: script, loader mode -> $interpRel"
            else
                {
                    printf 'd\0%s\0' "$interpRel"
                    for a in "${interpArgs[@]}"; do [[ -n "$a" ]] && printf '%s\0' "$a"; done
                    printf '%s\0' "$scriptDest"
                } > "$manifest"
                echo "$f: script, direct mode -> $interpRel"
            fi
            continue
        fi

        # ---- not a script: dynamic ELF executable? ----
        local loaderAbs
        loaderAbs="$(patchelf --print-interpreter "$f" 2>/dev/null || true)"
        [[ -z "$loaderAbs" ]] && continue   # static ELF, shared lib, or data

        local progDest loaderRel libdirsRel
        progDest=".$base.real"
        loaderRel="$(realpath --no-symlinks --relative-to="$dir" "$loaderAbs")"
        libdirsRel="$(_ensureFarm "$f" "$dir")"   # closure of the binary itself

        mv "$f" "$dir/$progDest"
        cp "$relocatableLauncher" "$f"; chmod +x "$f"
        printf 'e\0%s\0%s\0%s\0' "$loaderRel" "$libdirsRel" "$progDest" > "$manifest"
        echo "$f: dynamic ELF, elf mode"
    done < <(find "$@" -type f -perm -0100 -print0)
}

# Back-compat alias.
relocateShebangs() { relocateExecutables "$@"; }
