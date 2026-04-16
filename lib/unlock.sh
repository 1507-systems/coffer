#!/usr/bin/env bash
# unlock.sh -- Read age secret key from Keychain and export SOPS_AGE_KEY
# Usage: eval $(coffer unlock)
#
# Reads the age secret key directly from macOS Keychain.
# On headless machines (Wiles), also writes a session key file for persistence.
set -euo pipefail

cmd_unlock() {
    local secret_key=""

    # Check environment first -- already unlocked
    if [[ -n "${SOPS_AGE_KEY:-}" ]]; then
        log "Already unlocked (SOPS_AGE_KEY set)"
        echo "export SOPS_AGE_KEY='${SOPS_AGE_KEY}'"
        return 0
    fi

    # Check session key file (headless machines persist across shell sessions)
    local session_key_file="${COFFER_SESSION_KEY}"
    if [[ -f "$session_key_file" ]]; then
        secret_key=$(cat "$session_key_file")
        if [[ -n "$secret_key" ]]; then
            log "Using session key from ${session_key_file}"
            echo "export SOPS_AGE_KEY='${secret_key}'"
            return 0
        fi
    fi

    # Read secret key from Keychain
    secret_key=$(security find-generic-password -s "Coffer" -a "coffer-secret-key" -w 2>/dev/null) || {
        coffer_ntfy_urgent "Coffer Locked" "Unlock failed: secret key not found in Keychain."
        die "Secret key not found in Keychain. Run: coffer init"
    }

    [[ -n "$secret_key" ]] || die "Empty secret key in Keychain"

    # Validate it looks like an age secret key
    [[ "$secret_key" == AGE-SECRET-KEY-* ]] || die "Keychain entry is not a valid age secret key"

    log "Unlocked from Keychain"

    # On headless machines (Wiles), write session key file for persistence
    local config_dir="${COFFER_CONFIG_DIR}"
    local machine_name=""
    if [[ -f "${config_dir}/machine-name" ]]; then
        machine_name=$(cat "${config_dir}/machine-name")
    fi

    # Lowercase-compare using `tr` rather than ${var,,} — that expansion is
    # bash 4+ only, and macOS ships bash 3.2 at /bin/bash. Using ${var,,}
    # caused `coffer unlock` to print `bad substitution` and abort on the
    # default interpreter, breaking the session-key persistence path.
    local machine_name_lc
    machine_name_lc="$(printf '%s' "$machine_name" | tr '[:upper:]' '[:lower:]')"

    if [[ "$machine_name_lc" == "wiles" ]]; then
        mkdir -p "$(dirname "$session_key_file")"
        echo "$secret_key" > "$session_key_file"
        chmod 600 "$session_key_file"
        log "Session key written to ${session_key_file}"
    fi

    # Output the export command for eval $(coffer unlock)
    echo "export SOPS_AGE_KEY='${secret_key}'"
}
