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
    require_cmd jq
    require_identity
    ensure_unlocked
    parse_path "$path"

    # Read the public key for encrypting (stored during init)
    local public_key_file="${LOCKBOX_CONFIG_DIR}/public-key"
    [[ -f "$public_key_file" ]] || die "Public key not found at ${public_key_file}. Run: lockbox init"
    local age_recipient
    age_recipient=$(cat "$public_key_file")
    [[ -n "$age_recipient" ]] || die "Empty public key file"

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

    # All vault operations use JSON for data manipulation to avoid yq's YAML
    # parsing issues with special characters (%, !, $, etc. in passwords).
    # sops handles the YAML encryption layer; we never parse decrypted YAML ourselves.

    # If the category file doesn't exist or is empty, create it with just this key
    if [[ ! -f "$LOCKBOX_VAULT_FILE" ]] || [[ ! -s "$LOCKBOX_VAULT_FILE" ]]; then
        log "Creating new category: ${LOCKBOX_CATEGORY}"
        jq -n --arg key "$LOCKBOX_KEY" --arg val "$value" '{($key): $val}' \
            | SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops encrypt \
                --age "$age_recipient" \
                --input-type json --output-type yaml \
                /dev/stdin > "$LOCKBOX_VAULT_FILE" \
            || die "Failed to encrypt new category file: ${LOCKBOX_CATEGORY}"
        log "Set ${path}"
        return 0
    fi

    # Decrypt to JSON, update with jq, re-encrypt to YAML
    local updated
    updated=$(SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops decrypt --output-type json "$LOCKBOX_VAULT_FILE" \
        | jq --arg key "$LOCKBOX_KEY" --arg val "$value" '.[$key] = $val') \
        || die "Failed to decrypt/update '${LOCKBOX_CATEGORY}'"

    echo "$updated" | SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops encrypt \
        --age "$age_recipient" \
        --input-type json --output-type yaml \
        /dev/stdin > "$LOCKBOX_VAULT_FILE" \
        || die "Failed to re-encrypt '${LOCKBOX_CATEGORY}'"

    log "Set ${path}"
}
