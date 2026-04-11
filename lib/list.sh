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
            # Extract top-level keys, excluding the 'sops' metadata block
            yq 'keys | .[] | select(. != "sops")' "$f" | while IFS= read -r key; do
                echo "  ${key}"
            done
        done
    fi
}
