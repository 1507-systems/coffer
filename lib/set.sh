#!/usr/bin/env bash
# set.sh -- Store or update a secret in the vault
# Usage: lockbox set <category/key> [value] [--stdin]
set -euo pipefail

cmd_set() {
    local path=""
    local value=""
    local from_stdin=false
    local has_value=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stdin) from_stdin=true; shift ;;
            -*)      die "Unknown flag: $1" ;;
            *)
                if [[ -z "$path" ]]; then
                    path="$1"
                elif [[ "$has_value" == false ]]; then
                    value="$1"
                    has_value=true
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$path" ]] || die "Usage: lockbox set <category/key> [value] [--stdin]"

    require_cmd sops
    require_cmd yq
    require_identity
    ensure_unlocked
    parse_path "$path"

    # Get the value from stdin, argument, or interactive prompt
    if [[ "$from_stdin" == true ]]; then
        value=$(cat)
    elif [[ "$has_value" == false ]]; then
        # Interactive prompt (hidden input)
        printf 'Enter value for %s: ' "$path" >&2
        read -rs value
        echo >&2
        [[ -n "$value" ]] || die "Empty value provided"
    fi

    # If the category file doesn't exist, create it with just this key
    if [[ ! -f "$LOCKBOX_VAULT_FILE" ]]; then
        log "Creating new category: ${LOCKBOX_CATEGORY}"
        local new_content
        new_content=$(printf '%s: "%s"\n' "$LOCKBOX_KEY" "$value" | yq '.')
        echo "$new_content" | SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops encrypt \
            --config "$LOCKBOX_SOPS_CONFIG" \
            --input-type yaml --output-type yaml \
            /dev/stdin > "$LOCKBOX_VAULT_FILE" \
            || die "Failed to encrypt new category file: ${LOCKBOX_CATEGORY}"
        log "Set ${path}"
        return 0
    fi

    # Decrypt the full category file to memory
    local content
    content=$(SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops decrypt "$LOCKBOX_VAULT_FILE" 2>&1) \
        || die "Failed to decrypt '${LOCKBOX_CATEGORY}': ${content}"

    # Update the key-value pair using yq
    local updated
    updated=$(echo "$content" | yq ".\"${LOCKBOX_KEY}\" = \"${value}\"") \
        || die "Failed to update key '${LOCKBOX_KEY}' in '${LOCKBOX_CATEGORY}'"

    # Re-encrypt and write back
    echo "$updated" | SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops encrypt \
        --config "$LOCKBOX_SOPS_CONFIG" \
        --input-type yaml --output-type yaml \
        /dev/stdin > "$LOCKBOX_VAULT_FILE" \
        || die "Failed to re-encrypt '${LOCKBOX_CATEGORY}'"

    log "Set ${path}"
}
