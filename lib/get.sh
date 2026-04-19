#!/usr/bin/env bash
# get.sh -- Retrieve a secret value from the vault
# Usage: coffer get <category/key> [--newline|-n] [--clip|-c]
set -euo pipefail

cmd_get() {
    local path=""
    local newline=false
    local clip=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --newline|-n) newline=true; shift ;;
            --clip|-c)    clip=true; shift ;;
            -*)           die "Unknown flag: $1" ;;
            *)
                if [[ -z "$path" ]]; then
                    path="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$path" ]] || die "Usage: coffer get <category/key>"

    require_cmd sops
    # ensure_unlocked performs the same existence/readability/non-empty
    # checks as require_identity before loading the key, so calling
    # require_identity first would just duplicate the stat() calls. Keep
    # it as a single call site for identity loading.
    ensure_unlocked
    parse_path "$path"

    [[ -f "$COFFER_VAULT_FILE" ]] || die "Category '${COFFER_CATEGORY}' not found. Available: $(list_categories | tr '\n' ' ')"

    # Decrypt and extract the specific key
    local value
    value=$(SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops decrypt --extract "[\"${COFFER_KEY}\"]" "$COFFER_VAULT_FILE" 2>&1) \
        || die "Failed to decrypt '${COFFER_KEY}' from '${COFFER_CATEGORY}': ${value}"

    if [[ "$clip" == true ]]; then
        require_cmd pbcopy
        printf '%s' "$value" | pbcopy
        log "Copied to clipboard. Auto-clearing in 30 seconds."
        # Clear clipboard after 30 seconds in the background
        (sleep 30 && printf '' | pbcopy) &
        disown
    elif [[ "$newline" == true ]]; then
        printf '%s\n' "$value"
    else
        printf '%s' "$value"
    fi
}
