#!/usr/bin/env bash
# init.sh -- First-time coffer setup on a new machine
#
# Generates an age keypair and writes the secret key to the session-key file
# at ${COFFER_SESSION_KEY} (default ~/.config/coffer/.session-key, mode 600).
# That file is the single source of truth for coffer's identity — there is no
# Keychain path. The public key is saved alongside for SOPS recipient management,
# and a default SOPS config + empty vault categories are created on first run.
#
# Usage:
#   coffer init           # fresh setup; refuses if identity already exists
#   coffer init --force   # overwrite an existing identity file (destructive)
set -euo pipefail

cmd_init() {
    # --- Argument parsing ---
    local force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            -h|--help)
                cat >&2 <<'EOF'
Usage: coffer init [--force]

Generates an age keypair and stores the secret key at
~/.config/coffer/.session-key (mode 600). If an identity file already exists,
init refuses to proceed unless --force is passed.
EOF
                return 0
                ;;
            *) die "Unknown argument to init: $1" ;;
        esac
    done

    require_cmd age
    require_cmd age-keygen
    require_cmd sops

    local config_dir="${COFFER_CONFIG_DIR}"
    local session_key_file="${COFFER_SESSION_KEY}"

    # --- Abort if identity already exists (unless --force) ---
    # We refuse by default so users don't accidentally overwrite a working
    # identity and lock themselves out of existing vault files that only
    # that identity can decrypt. --force is the intentional escape hatch.
    if [[ -e "$session_key_file" ]] && [[ "$force" != true ]]; then
        die "Identity already exists at ${session_key_file}. Pass --force to overwrite (DESTRUCTIVE: the old key will be unrecoverable)."
    fi

    # --- Create config directory with tight perms ---
    mkdir -p "$config_dir"
    chmod 700 "$config_dir"

    # --- Prompt for machine name (suggest based on hostname) ---
    # Machine name is used in ntfy alerts so multi-host vaults disclose
    # which machine produced a given event.
    local hostname_suggestion
    hostname_suggestion=$(hostname -s 2>/dev/null || echo "unknown")
    printf 'Machine name [%s]: ' "$hostname_suggestion" >&2
    read -r machine_name
    machine_name="${machine_name:-$hostname_suggestion}"
    echo "$machine_name" > "${config_dir}/machine-name"
    log "Machine name set to: ${machine_name}"

    # --- Generate age keypair ---
    log "Generating age keypair..."
    local keygen_output
    keygen_output=$(age-keygen 2>&1)

    local public_key
    public_key=$(echo "$keygen_output" | grep -oE "age1[a-z0-9]+" | head -1)
    [[ -n "$public_key" ]] || die "Failed to extract public key from age-keygen output"

    local secret_key
    secret_key=$(echo "$keygen_output" | grep "^AGE-SECRET-KEY-")
    [[ -n "$secret_key" ]] || die "Failed to extract secret key from age-keygen output"

    # --- Write secret key to session-key file (single source of truth) ---
    # chmod is applied before content so the file is never briefly world-readable.
    # The default umask on macOS is 022 (644 for files), which would leak the
    # file contents to other users on a shared machine. We create with 600 up-front.
    log "Writing secret key to ${session_key_file}..."
    local old_umask
    old_umask=$(umask)
    umask 077
    printf '%s\n' "$secret_key" > "$session_key_file"
    umask "$old_umask"
    chmod 600 "$session_key_file"

    # Store public key alongside (not secret, used for SOPS config + recipients).
    echo "$public_key" > "${config_dir}/public-key"
    chmod 644 "${config_dir}/public-key"

    # --- Create SOPS config if missing (first machine setup) ---
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

    # --- Create vault directory and empty category placeholders ---
    mkdir -p "${COFFER_VAULT}"
    local categories=("cloudflare" "github" "home-automation" "synology" "communications" "misc")
    for cat_name in "${categories[@]}"; do
        local vault_file="${COFFER_VAULT}/${cat_name}.yaml"
        if [[ ! -f "$vault_file" ]]; then
            touch "$vault_file"
        fi
    done

    # --- Summary ---
    echo "" >&2
    log "Coffer initialized successfully!"
    log "Machine: ${machine_name}"
    log "Public key: ${public_key}"
    log "Secret key stored in: ${session_key_file} (mode 600)"
    echo "" >&2
    log "Next steps:"
    log "  1. On the OTHER machine, run: coffer add-recipient ${public_key}"
    log "  2. Import secrets: coffer import keychain-backup.csv"
    log "  3. (Optional) Load the key into your current shell: eval \$(coffer unlock)"
}
