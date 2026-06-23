# Build-time hook: replace script shebangs with the relocatable launcher.
#
# Derived from nixpkgs' patchShebangs (the shebang-parsing half is the same);
# the difference is the *output*: instead of rewriting the `#!` line to an
# absolute store path, we
#
#   1. move the real script aside (to <dir>/.<name>.script),
#   2. drop a copy of the launcher at the original path,
#   3. write a NUL-separated sidecar (<launcher>.rb) describing the interpreter
#      (relative to the launcher) and the relative script path.
#
# Usage in a derivation:
#   dontPatchShebangs = true;
#   nativeBuildInputs = [ relocatableShebangsHook ];
#   # (or call `relocateShebangs $out/bin` directly in postFixup)
#
# Requires $relocatableLauncher to point at the launcher binary (set by the
# setup hook).

relocateShebangs() {
    local interpreterArgsFromEnv=()

    local f
    while IFS= read -r -d $'\0' f; do
        isScript "$f" || continue

        local oldInterpreterLine
        read -r oldInterpreterLine < "$f" || [ "$oldInterpreterLine" ]

        local oldPath arg0 args
        read -r oldPath arg0 args <<< "${oldInterpreterLine:2}"

        local newPath interpArgs
        interpArgs=()

        if [[ "$oldPath" == *"/bin/env" ]]; then
            # `#!/usr/bin/env foo [args]` -> resolve foo on HOST_PATH/PATH.
            # NOTE: -S splitting is not yet handled; rejected for now.
            if [[ $arg0 == "-"* || $arg0 == *"="* ]]; then
                echo "$f: unsupported env directive \"$oldInterpreterLine\"" >&2
                exit 1
            fi
            newPath="$(PATH="${HOST_PATH:-$PATH}" type -P "$arg0" || true)"
            # remaining args after the interpreter
            read -r -a interpArgs <<< "$args"
        elif [[ "$oldPath" == /* && -x "$oldPath" ]]; then
            # Already an absolute path to a real interpreter (e.g. a store
            # path): honor it directly and just make it relative. Do NOT
            # re-resolve by basename, which could swap in a different (and
            # possibly non-relocatable) interpreter.
            newPath="$oldPath"
            local rest="$arg0 $args"
            read -r -a interpArgs <<< "$rest"
        else
            if [[ -z $oldPath ]]; then
                oldPath="/bin/sh"
            fi
            newPath="$(PATH="${HOST_PATH:-$PATH}" type -P "$(basename "$oldPath")" || true)"
            # original arg0/args become interpreter args
            local rest="$arg0 $args"
            read -r -a interpArgs <<< "$rest"
        fi

        if [[ -z "$newPath" ]]; then
            echo "$f: could not resolve interpreter for \"$oldInterpreterLine\"" >&2
            exit 1
        fi

        local dir base
        dir="$(dirname "$f")"
        base="$(basename "$f")"

        # interpreter path relative to the launcher's directory
        local interpRel
        interpRel="$(realpath --no-symlinks --relative-to="$dir" "$newPath")"

        # move the real script aside
        local scriptDest=".$base.script"
        mv "$f" "$dir/$scriptDest"

        # drop the launcher in its place
        cp "$relocatableLauncher" "$f"
        chmod +x "$f"

        # write the sidecar: interpRel \0 [args \0 ...] scriptRel \0
        {
            printf '%s\0' "$interpRel"
            local a
            for a in "${interpArgs[@]}"; do
                [[ -n "$a" ]] && printf '%s\0' "$a"
            done
            printf '%s\0' "$scriptDest"
        } > "$f.rb"

        echo "$f: relocatable launcher -> $interpRel (+$scriptDest)"
    done < <(find "$@" -type f -perm -0100 -print0)
}

# Register as a fixup hook unless disabled.
relocateShebangsAuto() {
    if [[ -z "${dontRelocateShebangs-}" && -e "$prefix" ]]; then
        relocateShebangs "$prefix"
    fi
}

# Opt-in: callers add this hook explicitly, or set relocateShebangsAuto in
# fixupOutputHooks.
