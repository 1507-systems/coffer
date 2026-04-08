#!/usr/bin/env bash
# get.sh -- Retrieve a secret value from the vault
# Usage: lockbox get <category/key> [--newline|-n] [--clip|-c]
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

    [[ -n "$path" ]] || die "Usage: lockbox get <category/key>"

    require_cmd sops
    require_identity
    ensure_unlocked
    parse_path "$path"

    [[ -f "$LOCKBOX_VAULT_FILE" ]] || die "Category '${LOCKBOX_CATEGORY}' not found. Available: $(list_categories | tr '\n' ' ')"

    # Decrypt and extract the specific key
    local value
    value=$(SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops decrypt --extract "[\"${LOCKBOX_KEY}\"]" "$LOCKBOX_VAULT_FILE" 2>&1) \
        || die "Failed to decrypt '${LOCKBOX_KEY}' from '${LOCKBOX_CATEGORY}': ${value}"

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
