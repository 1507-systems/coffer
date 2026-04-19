#!/usr/bin/env bash
# set.sh -- Store or update a secret in the vault
# Usage: coffer set <category/key> [value] [--stdin]
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

    [[ -n "$path" ]] || die "Usage: coffer set <category/key> [value] [--stdin]"

    require_cmd sops
    require_cmd jq
    # ensure_unlocked handles the "identity missing?" check before it
    # loads the key, so there's no need for a separate require_identity
    # call — it would only repeat the same stat() calls.
    ensure_unlocked
    parse_path "$path"

    # Encryption recipients come from .sops.yaml (COFFER_SOPS_CONFIG), NOT from
    # the local public-key file. Passing --age on the command line overrides
    # .sops.yaml entirely and silently drops every other recipient — which is
    # exactly the bug that locked Wiles out of cloudflare/* and ai/* in
    # April 2026, because every cross-machine `coffer set` re-encrypted with
    # only the writing machine's key.
    #
    # SOPS matches creation_rules.path_regex against the input filename; when
    # we pipe via /dev/stdin we have no filename, so we use --filename-override
    # to point at the destination vault file path.
    local sops_config="${COFFER_SOPS_CONFIG}"
    [[ -f "$sops_config" ]] || die "SOPS config not found at ${sops_config}. Run: coffer init"

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
    if [[ ! -f "$COFFER_VAULT_FILE" ]] || [[ ! -s "$COFFER_VAULT_FILE" ]]; then
        log "Creating new category: ${COFFER_CATEGORY}"
        # shellcheck disable=SC2094
        # SC2094 is a false positive here: --filename-override is just a path
        # string SOPS uses to match .sops.yaml creation_rules; sops never reads
        # that file. The actual input comes from /dev/stdin.
        jq -n --arg key "$COFFER_KEY" --arg val "$value" '{($key): $val}' \
            | SOPS_AGE_KEY="${SOPS_AGE_KEY}" SOPS_CONFIG="$sops_config" sops encrypt \
                --filename-override "$COFFER_VAULT_FILE" \
                --input-type json --output-type yaml \
                /dev/stdin > "$COFFER_VAULT_FILE" \
            || die "Failed to encrypt new category file: ${COFFER_CATEGORY}"
        log "Set ${path}"
        return 0
    fi

    # Decrypt to JSON, update with jq, re-encrypt to YAML.
    # Same recipient-preservation reasoning as the create path above.
    local updated
    updated=$(SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops decrypt --output-type json "$COFFER_VAULT_FILE" \
        | jq --arg key "$COFFER_KEY" --arg val "$value" '.[$key] = $val') \
        || die "Failed to decrypt/update '${COFFER_CATEGORY}'"

    # shellcheck disable=SC2094
    echo "$updated" | SOPS_AGE_KEY="${SOPS_AGE_KEY}" SOPS_CONFIG="$sops_config" sops encrypt \
        --filename-override "$COFFER_VAULT_FILE" \
        --input-type json --output-type yaml \
        /dev/stdin > "$COFFER_VAULT_FILE" \
        || die "Failed to re-encrypt '${COFFER_CATEGORY}'"

    log "Set ${path}"
}
