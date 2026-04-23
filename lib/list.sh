#!/usr/bin/env bash
# list.sh -- List categories and keys in the vault
# Usage: coffer list [category]
# No decryption needed -- SOPS leaves keys in plaintext.
set -euo pipefail

cmd_list() {
    require_cmd yq

    local category="${1:-}"

    if [[ -n "$category" ]]; then
        # List keys within a specific category
        list_keys_in_category "$category"
    else
        # List all categories and their keys in tree format
        local vault_dir="${COFFER_VAULT}"
        if [[ ! -d "$vault_dir" ]] || [[ -z "$(ls -A "$vault_dir" 2>/dev/null)" ]]; then
            die "No vault files found. Run: coffer init"
        fi

        for f in "${vault_dir}"/*.yaml; do
            local cat_name
            cat_name=$(basename "$f" .yaml)
            echo "${cat_name}/"
            # Bug C fix: a vault file whose top-level YAML node is null (e.g.,
            # an empty file or one containing only the literal "null") causes
            # `yq 'keys | .[]'` to emit the error "cannot get keys of !!null"
            # and — because the error propagates through the pipe — previously
            # halted the entire loop, silently skipping subsequent categories.
            #
            # Fix strategy:
            #   1. Ask yq for the node type first (type returns "null" for both
            #      an empty file and a file containing `null`; returns "!!map"
            #      for a real SOPS-encrypted or plaintext map).
            #   2. If the type isn't a map, skip key enumeration and print a
            #      brief "(empty)" note so the user knows the category exists
            #      but has no keys. This keeps list non-fatal for stale/corrupt
            #      files introduced during aborted `coffer set` runs.
            #   3. Continue to the next file regardless — one bad file must not
            #      stop the rest of the listing (achieved by `|| true` wrapper
            #      inside the subshell).
            local node_type
            node_type=$(yq 'type' "$f" 2>/dev/null || echo "error")
            if [[ "$node_type" != "!!map" ]]; then
                echo "  (empty)"
                continue
            fi
            # Extract top-level keys, excluding the 'sops' metadata block.
            # `|| true` prevents a yq error on any unexpected content from
            # aborting the outer loop via set -e.
            yq 'keys | .[] | select(. != "sops")' "$f" 2>/dev/null | while IFS= read -r key; do
                echo "  ${key}"
            done || true
        done
    fi
}
