#!/usr/bin/env bash
# merge-driver.sh -- coffer-aware SOPS git merge driver
#
# WHY THIS EXISTS:
# coffer vault category files are SOPS-encrypted YAML: an opaque AES-GCM blob
# plus a document-wide MAC. Two logically non-conflicting writes (different keys
# in the same category file) still touch the same ciphertext, which git cannot
# 3-way text-merge -- it conflicts, and auto_sync_pull's rebase die()s. See the
# 2026-06-03 incident in docs/plans/2026-06-03-coffer-sops-merge-driver.md.
#
# This file implements `coffer merge-driver`, a git custom merge driver that:
#   - decrypts base/ours/theirs to JSON IN MEMORY,
#   - unions the decrypted key MAPS (different-key writes merge cleanly),
#   - surfaces TRUE conflicts (same key, different values; delete-vs-modify)
#     by exiting non-zero so git marks the path conflicted,
#   - re-encrypts the clean-merge result to the CURRENT config/.sops.yaml
#     recipients (which also heals recipient drift on every merge).
#
# SECURITY (non-negotiable): decrypted plaintext exists ONLY in shell variables
# and in mode-0600 files inside a mode-0700 per-invocation temp dir under
# $TMPDIR. It is NEVER written to the working tree, git objects, stdout, or
# logs, and is NEVER placed on a process argv (jq inputs are fed via
# --slurpfile, not --argjson, to keep them off /proc/<pid>/cmdline). Conflict
# diagnostics print KEY NAMES ONLY, never values. A trap shreds/overwrites all
# temp files on exit.
#
# Sourced by bin/coffer; never executed directly.
set -euo pipefail

# _md_secure_wipe <file>...
#
# Best-effort secure deletion of plaintext-bearing temp files. macOS has no
# `shred`, so we fall back to `rm -P` (overwrite) and finally plain `rm`.
# FileVault is the real at-rest guarantee (matches coffer's documented threat
# model in SPEC.md); this is defense-in-depth for the brief on-disk window.
_md_secure_wipe() {
    local f
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        if command -v shred >/dev/null 2>&1; then
            shred -u "$f" 2>/dev/null && continue
        fi
        # macOS / BSD: -P overwrites before unlinking.
        rm -P "$f" 2>/dev/null && continue
        rm -f "$f" 2>/dev/null || true
    done
}

# _md_decrypt_to_json <path> -> JSON on stdout
#
# Decrypt a SOPS YAML side to a JSON object, IN MEMORY (command substitution).
# Returns "{}" for an empty/absent/never-encrypted side so add/add (no base) and
# uninitialized-category cases merge as empty maps. The decrypted "sops" metadata
# key is stripped here -- we never merge metadata, we re-derive it on re-encrypt.
#
# Exit non-zero ONLY when a non-empty, SOPS-encrypted file fails to decrypt
# (e.g. this machine lacks the age key) -- the caller turns that into a loud
# conflict rather than corrupting the merge.
_md_decrypt_to_json() {
    local path="$1"

    # Missing or zero-byte side -> empty map (e.g. base of an add/add).
    if [[ ! -s "$path" ]]; then
        printf '{}'
        return 0
    fi

    # A file with no `sops:` block was never encrypted (uninitialized category).
    # Mirrors the grep guard in add-recipient.sh. Treat as an empty map.
    if ! grep -q '^sops:' "$path" 2>/dev/null; then
        printf '{}'
        return 0
    fi

    local decrypted
    # ensure_unlocked (via the dispatcher) has already loaded SOPS_AGE_KEY.
    # Decrypt to JSON, then strip the sops metadata key with jq. We never echo
    # $decrypted anywhere except into the next pipe stage.
    #
    # --input-type yaml is REQUIRED: git names the merge temp files
    # `.merge_file_XXXX` with no extension, so sops can't infer the format and
    # would fail. Our vault category files are always YAML, so pin it.
    if ! decrypted=$(SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops decrypt --input-type yaml --output-type json "$path" 2>/dev/null); then
        return 1
    fi
    # del(.sops) drops metadata; if the result isn't an object, fail loudly.
    printf '%s' "$decrypted" | jq -e 'if type == "object" then del(.sops) else error("not an object") end' 2>/dev/null
}

# cmd_merge_driver %O %A %B %L %P
#
#   %O base   (merge ancestor; may be empty for add/add)
#   %A ours   (THE DRIVER WRITES THE MERGED RESULT BACK HERE)
#   %B theirs
#   %L conflict-marker size (unused; accepted for the git contract)
#   %P pathname in the work tree (e.g. vault/cloudflare.yaml), used for
#      --filename-override so .sops.yaml path_regex matching still works
#
# Exit 0  -> clean merge, %A holds re-encrypted merged content.
# Exit 1  -> real conflict (or precondition failure); git marks %A conflicted.
cmd_merge_driver() {
    local base="${1:-}"
    local ours="${2:-}"
    local theirs="${3:-}"
    # shellcheck disable=SC2034  # marker_size is part of the git contract, unused here
    local marker_size="${4:-}"
    local path="${5:-vault/unknown.yaml}"

    require_cmd sops
    require_cmd jq
    # The merging machine MUST hold the age private key (same precondition as
    # any coffer read/write). If it can't unlock, exit 1 (loud conflict) rather
    # than corrupting the file.
    ensure_unlocked

    local sops_config="${COFFER_SOPS_CONFIG}"
    if [[ ! -f "$sops_config" ]]; then
        echo "coffer merge-driver: SOPS config not found at ${sops_config}; cannot re-encrypt -- leaving '${path}' conflicted" >&2
        return 1
    fi

    # Per-invocation mode-0700 temp dir under $TMPDIR for all plaintext we must
    # materialize (the three decrypted-JSON inputs for jq, and the re-encrypt
    # input). Created BEFORE any plaintext is written, with umask 077 held until
    # AFTER the last plaintext file write so every file inside gets mode 0600.
    local prev_umask
    prev_umask=$(umask)
    umask 077
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/coffer-merge.XXXXXX") || {
        umask "$prev_umask"
        echo "coffer merge-driver: could not create secure temp dir -- leaving '${path}' conflicted" >&2
        return 1
    }
    # belt-and-suspenders: mktemp -d already used umask 077 (0700 dir), but
    # chmod 700 makes intent explicit and survives unusual umask defaults.
    chmod 700 "$tmpdir" 2>/dev/null || true
    # NOTE: umask 077 stays active until after merged_plain is written (below).

    local base_plain="${tmpdir}/base.json"
    local ours_plain="${tmpdir}/ours.json"
    local theirs_plain="${tmpdir}/theirs.json"
    local merged_plain="${tmpdir}/merged.json"
    # Shred plaintext temp files and remove the dir on ANY exit path.
    # shellcheck disable=SC2064  # expand vars now, intentionally
    trap "_md_secure_wipe '${base_plain}' '${ours_plain}' '${theirs_plain}' '${merged_plain}'; rm -rf '${tmpdir}' 2>/dev/null || true" EXIT INT TERM

    # --- 1. Decrypt all three sides to JSON, in memory ---
    local base_json ours_json theirs_json
    if ! base_json=$(_md_decrypt_to_json "$base"); then
        echo "coffer merge-driver: failed to decrypt base of '${path}' (missing age key?) -- leaving conflicted" >&2
        return 1
    fi
    if ! ours_json=$(_md_decrypt_to_json "$ours"); then
        echo "coffer merge-driver: failed to decrypt our side of '${path}' (missing age key?) -- leaving conflicted" >&2
        return 1
    fi
    if ! theirs_json=$(_md_decrypt_to_json "$theirs"); then
        echo "coffer merge-driver: failed to decrypt their side of '${path}' (missing age key?) -- leaving conflicted" >&2
        return 1
    fi

    # Write the three decrypted-JSON blobs to 0600 files in the secure temp dir
    # so jq can read them via --slurpfile (file-based, off the process argv).
    # umask 077 is still active here, so these files are created at mode 0600.
    # Passing large JSON via --argjson would put the plaintext on the process
    # argv, visible to same-user processes via /proc/<pid>/cmdline or `ps`.
    printf '%s' "$base_json"   > "$base_plain"
    printf '%s' "$ours_json"   > "$ours_plain"
    printf '%s' "$theirs_json" > "$theirs_plain"
    # Shell vars no longer needed; unset to limit plaintext lifetime in memory.
    unset base_json ours_json theirs_json

    # --- 2 & 3. Three-way map merge in jq. ---
    #
    # jq computes the union/conflict set entirely on the JSON objects; no
    # plaintext value is ever printed. The program emits, on stdout, a fixed
    # two-field ENVELOPE: {"conflicts":[<key names>], "result":{<merged map>}}.
    # Using a wrapper object (rather than a sentinel key inside the merged map)
    # means conflict detection can NEVER be spoofed by a real secret whose key
    # happens to match a sentinel name -- the merged map lives under .result and
    # is structurally separate from .conflicts.
    #
    # Per-key resolution over the union of keys K = base ∪ ours ∪ theirs:
    #   ob/oo/ot = "key present in base/ours/theirs?"
    #   - changed on exactly one side vs base      -> take the changed side
    #   - added on exactly one side (absent base)  -> take it
    #   - deleted on one side, untouched on other  -> delete (honor deletion)
    #   - deleted on one side, MODIFIED on other   -> CONFLICT (delete-vs-modify)
    #   - present both sides, SAME value           -> take it
    #   - present both sides, DIFFERENT value, and
    #     at least one differs from base           -> CONFLICT
    local merge_program
    # $base/$ours/$theirs are loaded via --slurpfile (each becomes a 1-element
    # array; access the object as $base[0] etc). This keeps plaintext off the
    # process argv entirely. SC2016: the $-vars in this string are jq variables,
    # NOT shell expansions.
    # shellcheck disable=SC2016
    merge_program='
      ($base[0])   as $b
      | ($ours[0])   as $o
      | ($theirs[0]) as $t
      | (($b|keys) + ($o|keys) + ($t|keys) | unique) as $allkeys
      | reduce $allkeys[] as $k ( {result:{}, conflicts:[]};
          ($b|has($k))   as $hb
        | ($o|has($k))   as $ho
        | ($t|has($k))   as $ht
        | ($b[$k])   as $bv
        | ($o[$k])   as $ov
        | ($t[$k])   as $tv
        | ($ho and $ht and ($ov == $tv)) as $same_both
        # ours-vs-base changed?
        | (if $ho then ($hb|not) or ($ov != $bv) else $hb end) as $ours_changed
        | (if $ht then ($hb|not) or ($tv != $bv) else $hb end) as $theirs_changed
        | if $same_both then
            .result[$k] = $ov
          elif ($ho and ($ht|not)) then
            # present in ours, absent in theirs
            if $theirs_changed and $ours_changed then
              .conflicts += [$k]
            elif $ours_changed then
              .result[$k] = $ov           # ours added/modified, theirs deleted-or-untouched
            else
              .                           # ours unchanged, theirs deleted -> delete
            end
          elif ($ht and ($ho|not)) then
            if $ours_changed and $theirs_changed then
              .conflicts += [$k]
            elif $theirs_changed then
              .result[$k] = $tv
            else
              .
            end
          elif ($ho and $ht) then
            # present on both, different values
            if $ours_changed and $theirs_changed then
              .conflicts += [$k]          # both changed it to different values
            elif $ours_changed then
              .result[$k] = $ov
            elif $theirs_changed then
              .result[$k] = $tv
            else
              .result[$k] = $ov           # neither changed (== base); keep
            end
          else
            # absent both ours and theirs -> deleted both -> drop
            .
          end
        )
      | {conflicts: (.conflicts | sort | unique), result: .result}
    '

    local envelope
    if ! envelope=$(jq -n \
            --slurpfile base   "$base_plain" \
            --slurpfile ours   "$ours_plain" \
            --slurpfile theirs "$theirs_plain" \
            "$merge_program" 2>/dev/null); then
        echo "coffer merge-driver: internal merge computation failed for '${path}' -- leaving conflicted" >&2
        return 1
    fi

    # Did the merge surface real conflicts? (.conflicts is a list of KEY NAMES.)
    local conflict_count
    conflict_count=$(printf '%s' "$envelope" | jq -r '.conflicts | length' 2>/dev/null || echo 0)
    if [[ "${conflict_count:-0}" -gt 0 ]]; then
        local conflict_keys
        conflict_keys=$(printf '%s' "$envelope" | jq -r '.conflicts | join(", ")' 2>/dev/null)
        echo "coffer merge-driver: TRUE conflict in '${path}' on key(s): ${conflict_keys}" >&2
        echo "coffer merge-driver: both sides set these to different values (or delete-vs-modify); resolve manually." >&2
        # Do NOT write %A; git leaves it as-is and marks the path conflicted.
        return 1
    fi

    # Extract just the merged map for re-encryption.
    local merge_out
    merge_out=$(printf '%s' "$envelope" | jq -c '.result' 2>/dev/null) || {
        echo "coffer merge-driver: failed to extract merged map for '${path}' -- leaving conflicted" >&2
        return 1
    }

    # --- 4. Clean merge: re-encrypt merged JSON to %A using CURRENT recipients ---
    #
    # Write the merged plaintext JSON to the mode-0700 temp file, then feed it to
    # sops encrypt. We pipe via the temp file (not the work tree) and capture the
    # ciphertext into a variable so a mid-encrypt failure never leaves a partial
    # plaintext or partial ciphertext in %A. --filename-override makes sops match
    # the vault/.*\.yaml$ creation_rule and pull the live recipient set, which is
    # what heals recipient drift on every merge.
    #
    # umask 077 is still active (deliberately kept since the mktemp call above)
    # so merged_plain is created at mode 0600, not the user's default 0644.
    printf '%s' "$merge_out" > "$merged_plain"
    # All plaintext file writes done; restore the caller's umask now.
    umask "$prev_umask"

    local ciphertext
    if ! ciphertext=$(SOPS_AGE_KEY="${SOPS_AGE_KEY}" SOPS_CONFIG="$sops_config" \
            sops encrypt \
                --filename-override "$path" \
                --input-type json --output-type yaml \
                "$merged_plain" 2>/dev/null); then
        echo "coffer merge-driver: failed to re-encrypt merged '${path}' to current recipients -- leaving conflicted" >&2
        return 1
    fi

    # Wipe the plaintext temp before touching %A.
    _md_secure_wipe "$merged_plain"

    # The ONLY thing ever written to %A is ciphertext.
    printf '%s\n' "$ciphertext" > "$ours" || {
        echo "coffer merge-driver: failed to write merged ciphertext to '${path}' -- leaving conflicted" >&2
        return 1
    }

    echo "coffer merge-driver: cleanly merged '${path}' (re-encrypted to current recipients)" >&2
    return 0
}
