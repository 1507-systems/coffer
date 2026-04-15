#!/usr/bin/env bash
# common.sh -- Shared helpers for coffer CLI
# Sourced by bin/coffer and all lib/ scripts. Never executed directly.
set -euo pipefail

# ntfy topic for urgent failure notifications
COFFER_NTFY_TOPIC="https://ntfy.1507.cloud/infra-alerts-0f1ddcff97b3"

# --- Logging ---

# Print an error message, send an ntfy urgent notification, and exit 1.
# Every failure in coffer is fatal and loud.
die() {
    echo "coffer: error: $*" >&2
    # Push urgent notification so the user knows immediately on any device
    curl -s -H "Priority: urgent" -H "Title: Coffer Error" -H "Tags: lock,warning" \
        -d "$*" "${COFFER_NTFY_TOPIC}" >/dev/null 2>&1 || true
    exit 1
}

# Print a warning to stderr. Does NOT send ntfy (non-fatal).
warn() {
    echo "coffer: warning: $*" >&2
}

# Print an informational log message to stderr.
log() {
    echo "coffer: $*" >&2
}

# --- Dependency checks ---

# Verify a command exists on PATH. Dies with install instructions if missing.
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found. Install: brew install $1"
}

# --- Identity and session key helpers ---

# Verify that coffer has been initialized (secret key exists in Keychain).
require_identity() {
    security find-generic-password -s "Coffer" -a "coffer-secret-key" -w >/dev/null 2>&1 \
        || die "No identity found. Run: coffer init"
}

# Ensure SOPS_AGE_KEY is available for decryption.
# Checks (in order): environment variable, session key file, Keychain, then fails.
ensure_unlocked() {
    # Already unlocked via environment
    if [[ -n "${SOPS_AGE_KEY:-}" ]]; then
        return 0
    fi

    # Fallback: check session key file (headless machines like Wiles)
    local session_key="${COFFER_SESSION_KEY:-${HOME}/.config/coffer/.session-key}"
    if [[ -f "$session_key" ]]; then
        SOPS_AGE_KEY="$(cat "$session_key")"
        export SOPS_AGE_KEY
        return 0
    fi

    # Fallback: try Keychain directly (interactive use on laptops)
    local kc_key
    kc_key=$(security find-generic-password -s "Coffer" -a "coffer-secret-key" -w 2>/dev/null) || true
    if [[ -n "$kc_key" ]] && [[ "$kc_key" == AGE-SECRET-KEY-* ]]; then
        SOPS_AGE_KEY="$kc_key"
        export SOPS_AGE_KEY
        return 0
    fi

    die "Vault is locked. Run: eval \$(coffer unlock)"
}

# --- SOPS wrapper ---

# Run sops with the coffer SOPS config file.
# Automatically sets SOPS_AGE_KEY if available.
run_sops() {
    ensure_unlocked
    SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops "$@"
}

# --- Vault path helpers ---

# Given "category/key", return the vault file path and the key name.
# Usage: parse_path "cloudflare/dns-token"
#   Sets: COFFER_CATEGORY, COFFER_KEY, COFFER_VAULT_FILE
parse_path() {
    local path="$1"
    if [[ "$path" != */* ]]; then
        die "Invalid path format: '${path}'. Expected: category/key"
    fi
    COFFER_CATEGORY="${path%%/*}"
    COFFER_KEY="${path#*/}"
    COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"  # exported for use by callers
    export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE

    [[ -n "$COFFER_CATEGORY" ]] || die "Empty category in path: '${path}'"
    [[ -n "$COFFER_KEY" ]] || die "Empty key in path: '${path}'"
}

# List available categories (vault YAML filenames without extension).
list_categories() {
    local vault_dir="${COFFER_VAULT:-${COFFER_ROOT}/vault}"
    if [[ ! -d "$vault_dir" ]] || [[ -z "$(ls -A "$vault_dir" 2>/dev/null)" ]]; then
        die "No vault files found. Run: coffer init"
    fi
    for f in "${vault_dir}"/*.yaml; do
        basename "$f" .yaml
    done
}

# List keys in a category file (SOPS leaves keys in plaintext).
# Excludes the 'sops' metadata key.
list_keys_in_category() {
    local category="$1"
    local vault_file="${COFFER_VAULT}/${category}.yaml"
    [[ -f "$vault_file" ]] || die "Category '${category}' not found. Available: $(list_categories | tr '\n' ' ')"
    require_cmd yq
    yq 'keys | .[] | select(. != "sops")' "$vault_file"
}
