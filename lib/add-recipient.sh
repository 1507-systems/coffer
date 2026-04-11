#!/usr/bin/env bash
# add-recipient.sh -- Add an age public key as an additional SOPS recipient
# Adds the key to .sops.yaml and re-encrypts all vault files so both
# machines (e.g., Verve and Wiles) can decrypt.
# Usage: coffer add-recipient <age-public-key>
set -euo pipefail

cmd_add_recipient() {
    local new_key="${1:-}"

    # Validate argument
    [[ -n "$new_key" ]] || die "Usage: coffer add-recipient <age-public-key>"

    # Validate the key looks like a valid age public key
    if [[ ! "$new_key" =~ ^age1[a-z0-9]{58}$ ]]; then
        die "Invalid age public key format. Expected: age1<58 lowercase alphanumeric chars>"
    fi

    require_cmd sops
    ensure_unlocked

    local sops_config="${COFFER_SOPS_CONFIG}"
    [[ -f "$sops_config" ]] || die "SOPS config not found at ${sops_config}. Run: coffer init"

    # Read the current age recipients from the SOPS config
    local current_recipients
    current_recipients=$(grep -A1 'age:' "$sops_config" | tail -1 | sed 's/^[[:space:]]*//')
    [[ -n "$current_recipients" ]] || die "Could not read current recipients from ${sops_config}"

    # Check if this key is already a recipient
    if echo "$current_recipients" | grep -qF "$new_key"; then
        log "Key ${new_key} is already a recipient. Nothing to do."
        return 0
    fi

    # Build the updated comma-separated recipient list
    local updated_recipients="${current_recipients},${new_key}"

    log "Adding recipient: ${new_key}"
    log "Updated recipient list: ${updated_recipients}"

    # Update the SOPS config file with the new recipient list
    # Rewrite the entire file to avoid sed edge cases with multi-line YAML
    cat > "$sops_config" <<SOPS_EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${updated_recipients}
SOPS_EOF

    log "Updated ${sops_config}"

    # Re-encrypt all existing vault files with the updated recipient list.
    # sops updatekeys reads the new .sops.yaml and adds/removes recipients
    # without needing to fully decrypt the data — just re-wraps the data key.
    local vault_dir="${COFFER_VAULT}"
    if [[ ! -d "$vault_dir" ]] || [[ -z "$(ls -A "$vault_dir" 2>/dev/null)" ]]; then
        log "No vault files to re-encrypt. Done."
        return 0
    fi

    local re_encrypted=0
    local skipped=0

    for vault_file in "${vault_dir}"/*.yaml; do
        local filename
        filename=$(basename "$vault_file")

        # Skip empty/uninitialized files (no sops metadata = never encrypted)
        if ! grep -q '^sops:' "$vault_file" 2>/dev/null; then
            log "Skipping ${filename} (not encrypted yet)"
            skipped=$((skipped + 1))
            continue
        fi

        log "Re-encrypting ${filename}..."
        # updatekeys re-wraps the data key for the new recipient list.
        # --yes skips the interactive confirmation prompt.
        if SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops updatekeys --yes --config "$sops_config" "$vault_file"; then
            re_encrypted=$((re_encrypted + 1))
        else
            die "Failed to re-encrypt ${filename}. Vault may be in an inconsistent state — check ${sops_config}"
        fi
    done

    echo "" >&2
    log "Recipient added successfully!"
    log "  Re-encrypted: ${re_encrypted} file(s)"
    log "  Skipped (not yet encrypted): ${skipped} file(s)"
    log ""
    log "Both machines can now decrypt the vault after syncing."
}
