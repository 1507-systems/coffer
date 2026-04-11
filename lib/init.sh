#!/usr/bin/env bash
# init.sh -- First-time coffer setup on a new machine
# Generates an age keypair, stores secret key in macOS Keychain, creates SOPS config.
# Usage: coffer init
set -euo pipefail

cmd_init() {
    require_cmd age
    require_cmd age-keygen
    require_cmd sops

    local config_dir="${COFFER_CONFIG_DIR}"

    # Check for existing identity in Keychain -- abort if already initialized
    if security find-generic-password -s "Coffer" -a "coffer-secret-key" -w >/dev/null 2>&1; then
        die "Identity already exists in Keychain. Run: coffer reset (or delete 'Coffer' entries from Keychain manually) to re-initialize."
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
    public_key=$(echo "$keygen_output" | grep -oE "age1[a-z0-9]+" | head -1)
    [[ -n "$public_key" ]] || die "Failed to extract public key from age-keygen output"

    local secret_key
    secret_key=$(echo "$keygen_output" | grep "^AGE-SECRET-KEY-")
    [[ -n "$secret_key" ]] || die "Failed to extract secret key from age-keygen output"

    # Store secret key in macOS Keychain (the only copy -- no file on disk)
    log "Storing secret key in Keychain..."
    security add-generic-password -s "Coffer" -a "coffer-secret-key" -w "$secret_key" \
        -T /usr/bin/security -T /bin/bash 2>/dev/null \
        || die "Failed to store secret key in Keychain. Cannot proceed without secure storage."

    # Store public key in config dir (not secret, used for SOPS config and recipient management)
    echo "$public_key" > "${config_dir}/public-key"
    chmod 644 "${config_dir}/public-key"

    # Create SOPS config if it doesn't exist
    local sops_config="${COFFER_SOPS_CONFIG}"
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
        log "Run 'coffer add-recipient ${public_key}' on the other machine to register this key."
    fi

    # Create vault directory and empty category files
    mkdir -p "${COFFER_VAULT}"
    local categories=("cloudflare" "github" "home-automation" "synology" "communications" "misc")
    for cat_name in "${categories[@]}"; do
        local vault_file="${COFFER_VAULT}/${cat_name}.yaml"
        if [[ ! -f "$vault_file" ]]; then
            touch "$vault_file"
        fi
    done

    echo "" >&2
    log "Coffer initialized successfully!"
    log "Machine: ${machine_name}"
    log "Public key: ${public_key}"
    log "Secret key stored in: macOS Keychain (service: Coffer)"
    echo "" >&2
    log "Next steps:"
    log "  1. On the OTHER machine, run: coffer add-recipient ${public_key}"
    log "  2. Import secrets: coffer import keychain-backup.csv"
    log "  3. Unlock the vault: eval \$(coffer unlock)"
}
