#!/usr/bin/env bash
# init.sh -- First-time lockbox setup on a new machine
# Generates an age keypair, creates SOPS config, and sets up vault structure.
# Usage: lockbox init
set -euo pipefail

cmd_init() {
    require_cmd age
    require_cmd age-keygen
    require_cmd sops

    local config_dir="${LOCKBOX_CONFIG_DIR}"
    local identity_file="${LOCKBOX_IDENTITY}"

    # Check for existing identity -- abort if already initialized
    if [[ -f "$identity_file" ]]; then
        die "Identity already exists at ${identity_file}. Remove it first if you want to re-initialize."
    fi

    # Create config directory
    mkdir -p "$config_dir"
    chmod 700 "$config_dir"

    # Prompt for machine name (suggest based on hostname)
    local hostname_suggestion
    hostname_suggestion=$(hostname -s 2>/dev/null || echo "unknown")
    printf 'Machine name [%s]: ' "$hostname_suggestion" >&2
    read -r machine_name
    machine_name="${machine_name:-$hostname_suggestion}"
    echo "$machine_name" > "${config_dir}/machine-name"
    log "Machine name set to: ${machine_name}"

    # Generate age keypair
    log "Generating age keypair..."
    local keygen_output
    keygen_output=$(age-keygen 2>&1)
    local public_key
    public_key=$(echo "$keygen_output" | grep "^age1")
    # The full output includes comments with the public key and the private key
    # age-keygen outputs: # created: <date>\n# public key: age1...\nAGE-SECRET-KEY-...
    [[ -n "$public_key" ]] || die "Failed to extract public key from age-keygen output"

    # Prompt for passphrase to encrypt the identity file
    printf 'Enter passphrase to protect the identity file: ' >&2
    read -rs passphrase
    echo >&2
    [[ -n "$passphrase" ]] || die "Passphrase cannot be empty"

    printf 'Confirm passphrase: ' >&2
    read -rs passphrase_confirm
    echo >&2
    [[ "$passphrase" == "$passphrase_confirm" ]] || die "Passphrases do not match"

    # Encrypt the private key with the passphrase using age's scrypt encryption.
    # We write the keygen output to a temp file, encrypt it, then shred the temp.
    log "Encrypting identity with passphrase..."
    local tmpkey
    tmpkey=$(mktemp)
    echo "$keygen_output" > "$tmpkey"
    chmod 600 "$tmpkey"
    echo "$passphrase" | age -p -o "$identity_file" "$tmpkey" 2>/dev/null \
        || die "Failed to encrypt identity file"
    # Overwrite and remove the temp file immediately
    dd if=/dev/zero of="$tmpkey" bs=1 count=256 conv=notrunc 2>/dev/null || true
    rm -f "$tmpkey"
    chmod 600 "$identity_file"

    # Offer to store passphrase in macOS Keychain for auto-unlock
    printf 'Store passphrase in macOS Keychain for auto-unlock at boot? [y/N]: ' >&2
    read -r store_keychain
    if [[ "$store_keychain" =~ ^[Yy]$ ]]; then
        log "Storing passphrase in Keychain..."
        log "NOTE: You must run this from a GUI terminal for Keychain ACL prompts."
        security add-generic-password -s "Lockbox" -a "lockbox" -w "$passphrase" \
            -T /usr/bin/security -T /bin/bash 2>/dev/null \
            || warn "Failed to store in Keychain. You can add it manually later."
    fi

    # Create SOPS config if it doesn't exist
    local sops_config="${LOCKBOX_SOPS_CONFIG}"
    if [[ ! -f "$sops_config" ]]; then
        log "Creating SOPS configuration..."
        mkdir -p "$(dirname "$sops_config")"
        cat > "$sops_config" <<SOPS_EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${public_key}
SOPS_EOF
        log "SOPS config created at ${sops_config}"
    else
        log "SOPS config already exists at ${sops_config}"
        log "Run 'lockbox add-recipient ${public_key}' on the other machine to register this key."
    fi

    # Create vault directory and empty category files
    mkdir -p "${LOCKBOX_VAULT}"
    local categories=("cloudflare" "github" "home-automation" "synology" "communications" "misc")
    for cat_name in "${categories[@]}"; do
        local vault_file="${LOCKBOX_VAULT}/${cat_name}.yaml"
        if [[ ! -f "$vault_file" ]]; then
            # Create a placeholder file (will be populated on first set/import)
            touch "$vault_file"
        fi
    done

    echo "" >&2
    log "Lockbox initialized successfully!"
    log "Machine: ${machine_name}"
    log "Public key: ${public_key}"
    log "Identity: ${identity_file}"
    echo "" >&2
    log "Next steps:"
    log "  1. On the OTHER machine, run: lockbox add-recipient ${public_key}"
    log "  2. Import secrets: lockbox import keychain-backup.csv"
    log "  3. Unlock the vault: eval \$(lockbox unlock)"
}
