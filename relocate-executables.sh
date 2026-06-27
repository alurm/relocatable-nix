# Build-time hook: make executables relocatable by replacing them with the
# self-locating launcher.
#
# It runs *after* nixpkgs' patchShebangs, so script shebangs are already
# normalized to absolute store paths (including `env`/`env -S` handling) — we do
# not re-parse `env`, we just read the resulting `#!<abs interp> <args>` line.
# So this composes with patchShebangs rather than reimplementing it.
#
# Per executable found under the given paths:
#   * shebang script        -> direct mode ("d") if the interpreter is static,
#                              loader mode ("l") if it is dynamic;
#   * dynamic ELF binary     -> elf mode ("e"), run via ld.so;
#   * static ELF / shared lib / data -> left alone.
#
# Each wrapped file is moved aside (.<name>.script or .<name>.real), a launcher
# copy is dropped in its place, and a NUL-separated manifest (.<name>.reloc) is
# written. The launcher binary is identical for every executable; per-item
# config is data, so no per-item compilation is needed.
#
# Dynamic executables need a library search path; it is derived automatically
# from each binary's transitive RPATH and collapsed into one per-output symlink
# farm (<out>/.reloc-libs) passed to `ld.so --library-path`. Set $relocLibPaths
# (store paths) to add extra lib dirs.
#
# Usage (after patchShebangs, e.g. in postFixup), or via the overlay:
#   postFixup = "relocateExecutables $out";

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
        local oldIFS="$IFS"
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
    declare -A _farmDirs=()

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

    # Ensure the farm covers $1's lib closure (+ its loader dir + overrides),
    # echo the farm path relative to $2.
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
        [[ "$base" == .* ]] && continue   # skip our hidden artifacts (idempotent)
        local manifest="$dir/.$base.reloc"

        if isScript "$f"; then
            # patchShebangs already normalized the shebang to "#!<abs> [args]".
            local line rest interp args
            read -r line < "$f" || [ "$line" ]
            rest="${line#\#!}"
            read -r interp args <<< "$rest"
            if [[ "$interp" != /* ]]; then
                echo "$f: shebang '$interp' is not absolute; run patchShebangs first" >&2
                exit 1
            fi
            if [[ "$interp" == */bin/env ]]; then
                # patchShebangs would have resolved env to a concrete interpreter;
                # seeing env here means it didn't run (e.g. dontPatchShebangs).
                echo "$f: shebang interpreter is env ('$interp'); enable patchShebangs so it resolves to a real interpreter before relocateExecutables" >&2
                exit 1
            fi
            local interpArgs=(); [[ -n "$args" ]] && read -r -a interpArgs <<< "$args"

            local interpRel scriptDest a loaderAbs
            interpRel="$(realpath --no-symlinks --relative-to="$dir" "$interp")"
            scriptDest=".$base.script"
            loaderAbs="$(patchelf --print-interpreter "$interp" 2>/dev/null || true)"

            mv "$f" "$dir/$scriptDest"
            cp "$relocatableLauncher" "$f"; chmod +x "$f"

            if [[ -n "$loaderAbs" ]]; then
                local loaderRel libdirsRel
                loaderRel="$(realpath --no-symlinks --relative-to="$dir" "$loaderAbs")"
                libdirsRel="$(_ensureFarm "$interp" "$dir")"
                {
                    printf 'l\0%s\0%s\0%s\0' "$loaderRel" "$libdirsRel" "$interpRel"
                    for a in "${interpArgs[@]}"; do [[ -n "$a" ]] && printf '%s\0' "$a"; done
                    printf '%s\0' "$scriptDest"
                } > "$manifest"
            else
                {
                    printf 'd\0%s\0' "$interpRel"
                    for a in "${interpArgs[@]}"; do [[ -n "$a" ]] && printf '%s\0' "$a"; done
                    printf '%s\0' "$scriptDest"
                } > "$manifest"
            fi
            continue
        fi

        # not a script: dynamic ELF executable?
        local loaderAbs
        loaderAbs="$(patchelf --print-interpreter "$f" 2>/dev/null || true)"
        [[ -z "$loaderAbs" ]] && continue   # static ELF, shared lib, or data

        local progDest loaderRel libdirsRel
        progDest=".$base.real"
        loaderRel="$(realpath --no-symlinks --relative-to="$dir" "$loaderAbs")"
        libdirsRel="$(_ensureFarm "$f" "$dir")"

        mv "$f" "$dir/$progDest"
        cp "$relocatableLauncher" "$f"; chmod +x "$f"
        printf 'e\0%s\0%s\0%s\0' "$loaderRel" "$libdirsRel" "$progDest" > "$manifest"
    done < <(find "$@" -type f -perm -0100 -print0)
}
