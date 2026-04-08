#!/usr/bin/env bash
# lock.sh -- Clear the session key and unset SOPS_AGE_KEY
# Usage: eval $(lockbox lock)
set -euo pipefail

cmd_lock() {
    local session_key_file="${LOCKBOX_SESSION_KEY:-${HOME}/.config/lockbox/.session-key}"

    # Delete the session key file if it exists
    if [[ -f "$session_key_file" ]]; then
        # Overwrite with zeros before deleting (defense in depth)
        dd if=/dev/zero of="$session_key_file" bs=1 count=256 conv=notrunc 2>/dev/null || true
        rm -f "$session_key_file"
        log "Session key file removed"
    fi

    # Output the unset command for eval $(lockbox lock)
    echo "unset SOPS_AGE_KEY"
    log "Vault locked"
}
