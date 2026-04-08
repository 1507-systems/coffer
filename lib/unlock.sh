#!/usr/bin/env bash
# unlock.sh -- Decrypt the age identity and export SOPS_AGE_KEY
# Usage: lockbox unlock [--auto]
#   --auto: Read passphrase from macOS Keychain (for LaunchAgent/headless use)
#
# For interactive shells: eval $(lockbox unlock)
# For headless machines: lockbox unlock --auto (writes session key file)
set -euo pipefail

cmd_unlock() {
    local auto=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) auto=true; shift ;;
            *)      die "Unknown flag: $1" ;;
        esac
    done

    require_cmd age
    require_identity

    local identity_file="${LOCKBOX_IDENTITY}"
    local session_key_file="${LOCKBOX_SESSION_KEY}"
    local passphrase=""

    if [[ "$auto" == true ]]; then
        # Read passphrase from macOS Keychain
        passphrase=$(security find-generic-password -s "Lockbox" -a "lockbox" -w 2>/dev/null) || {
            # Auto-unlock failed -- send urgent notification
            curl -s -H "Priority: urgent" -H "Title: Lockbox Locked" -H "Tags: lock,warning" \
                -d "Auto-unlock failed on $(hostname). Keychain read failed. Manual unlock required." \
                "${LOCKBOX_NTFY_TOPIC}" >/dev/null 2>&1 || true
            die "Auto-unlock failed: could not read passphrase from Keychain. Manual unlock required."
        }
    else
        # Interactive: read from stdin if piped, otherwise prompt
        if [[ -t 0 ]]; then
            printf 'Passphrase: ' >&2
            read -rs passphrase
            echo >&2
        else
            read -r passphrase
        fi
    fi

    [[ -n "$passphrase" ]] || die "Empty passphrase"

    # Decrypt the identity file to extract the age secret key
    local decrypted_key
    decrypted_key=$(echo "$passphrase" | age -d "$identity_file" 2>/dev/null) \
        || die "Failed to decrypt identity. Wrong passphrase?"

    # Extract just the secret key line (AGE-SECRET-KEY-...)
    local secret_key
    secret_key=$(echo "$decrypted_key" | grep "^AGE-SECRET-KEY-")
    [[ -n "$secret_key" ]] || die "No secret key found in decrypted identity"

    # Determine if we're on a headless machine (check for machine-name file)
    local config_dir="${LOCKBOX_CONFIG_DIR}"
    local machine_name=""
    if [[ -f "${config_dir}/machine-name" ]]; then
        machine_name=$(cat "${config_dir}/machine-name")
    fi

    # On headless machines (like Wiles), write the session key to a file
    # so it persists across shell sessions. On laptops, just export the env var.
    if [[ "$auto" == true ]] || [[ "$machine_name" == "wiles" ]]; then
        mkdir -p "$(dirname "$session_key_file")"
        echo "$secret_key" > "$session_key_file"
        chmod 600 "$session_key_file"
        log "Session key written to ${session_key_file}"
    fi

    # Output the export command for eval $(lockbox unlock)
    # The caller captures this stdout and evals it.
    echo "export SOPS_AGE_KEY='${secret_key}'"
}
