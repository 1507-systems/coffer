#!/usr/bin/env bash
# common.sh -- Shared helpers for coffer CLI
# Sourced by bin/coffer and all lib/ scripts. Never executed directly.
set -euo pipefail

# ntfy topic for urgent failure notifications
COFFER_NTFY_TOPIC="https://ntfy.1507.cloud/infra-alerts-0f1ddcff97b3"

# --- Logging ---

# Return the machine identity used in alert titles/tags.
# Prefers the coffer machine-name file (wiles/verve) and falls back to the
# short hostname if coffer hasn't been initialized. Always prints something.
coffer_machine_id() {
    local machine_id=""
    if [[ -f "${HOME}/.config/coffer/machine-name" ]]; then
        machine_id="$(cat "${HOME}/.config/coffer/machine-name" 2>/dev/null || echo '')"
    fi
    if [[ -z "$machine_id" ]]; then
        machine_id="$(hostname -s 2>/dev/null || echo unknown)"
    fi
    printf '%s' "$machine_id"
}

# Send an urgent ntfy alert tagged with the machine identity so multi-host
# vaults disclose which machine produced the error. The title carries the
# identity (lock screens show it) and the tag list includes it for filtering;
# the body stays unprefixed since repeating the identity there is noise.
coffer_ntfy_urgent() {
    local title="$1"
    local body="$2"
    local machine
    machine="$(coffer_machine_id)"
    curl -s \
        -H "Priority: urgent" \
        -H "Title: ${title} [${machine}]" \
        -H "Tags: lock,warning,${machine}" \
        -d "${body}" \
        "${COFFER_NTFY_TOPIC}" >/dev/null 2>&1 || true
}

# Print an error message, send an ntfy urgent notification, and exit 1.
# Every failure in coffer is fatal and loud.
die() {
    echo "coffer: error: $*" >&2
    coffer_ntfy_urgent "Coffer Error" "$*"
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
#
# Identity model (single source of truth, April 2026 refactor):
#   The age secret key lives in ONE place: the session-key file on disk at
#   ${COFFER_SESSION_KEY} (default ${HOME}/.config/coffer/.session-key), mode
#   600. If the file exists and is readable and non-empty, coffer has an
#   identity. If not, the user must run `coffer init`.
#
#   Previously coffer ALSO consulted macOS Keychain. That dual path produced
#   two bugs: (1) `require_identity` demanded Keychain access while
#   `ensure_unlocked` fell back to the file, so contexts where the Keychain is
#   unavailable (notably SSH-spawned processes, which don't inherit GUI login
#   Keychain access by default) died at identity-check even though the file
#   would have worked; (2) the Keychain entry could drift out of sync with
#   the file, producing "it works here but not there" reports. The refactor
#   removes Keychain entirely — FileVault + mode 600 + user isolation give
#   equivalent at-rest protection on an unlocked Mac without the dual-path
#   fragility. See SPEC.md "Identity and Unlock Model" for the threat model.

# Return the path coffer uses to read/write the identity file.
# Callers should use this rather than hardcoding the default so that tests
# and alternative configs honor COFFER_SESSION_KEY. bin/coffer exports
# COFFER_SESSION_KEY on startup; this fallback is only for scripts that
# source common.sh without going through the dispatcher.
coffer_session_key_path() {
    printf '%s' "${COFFER_SESSION_KEY:-${HOME}/.config/coffer/.session-key}"
}

# Verify that coffer has been initialized by confirming the session-key file
# exists, is readable, and is non-empty. Does NOT load the key into the
# environment — that's ensure_unlocked's job. Dies with an actionable message
# if the file is missing, unreadable, or empty.
require_identity() {
    local key_file
    key_file="$(coffer_session_key_path)"

    if [[ ! -e "$key_file" ]]; then
        die "No identity found at ${key_file}. Run: coffer init"
    fi
    if [[ ! -r "$key_file" ]]; then
        die "Identity file ${key_file} exists but is not readable by this user. Check ownership and permissions (expected: mode 600, owned by $(id -un))."
    fi
    if [[ ! -s "$key_file" ]]; then
        die "Identity file ${key_file} is empty. Run: coffer init (or restore from backup)."
    fi
}

# Ensure SOPS_AGE_KEY is exported for decryption.
# Exactly two paths, checked in order:
#   1. SOPS_AGE_KEY already set in the environment  -> use it as-is.
#   2. Session-key file on disk (single source of truth) -> load and export.
# No Keychain fallback. If neither is available, dies with guidance to run
# `coffer init`. See the block comment above for why.
ensure_unlocked() {
    # Already unlocked via environment — trust it. (Callers may have
    # eval'd `coffer unlock` earlier in the shell or exported the key
    # manually; no need to re-read the file.)
    if [[ -n "${SOPS_AGE_KEY:-}" ]]; then
        return 0
    fi

    local key_file
    key_file="$(coffer_session_key_path)"

    # File missing: identity isn't set up at all. require_identity would
    # have caught this if the caller invoked it first, but ensure_unlocked
    # is also called in isolation (e.g., from add-recipient) so it must
    # produce the same actionable error on its own.
    if [[ ! -f "$key_file" ]]; then
        die "No identity found at ${key_file}. Run: coffer init"
    fi

    # File present but unreadable/empty: treat as a corrupted identity
    # rather than silently falling through to a misleading "locked" error.
    if [[ ! -r "$key_file" ]]; then
        die "Identity file ${key_file} is not readable by this user."
    fi

    local key
    key="$(cat "$key_file")"
    if [[ -z "$key" ]]; then
        die "Identity file ${key_file} is empty. Run: coffer init (or restore from backup)."
    fi

    SOPS_AGE_KEY="$key"
    export SOPS_AGE_KEY
    return 0
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
    # Bug C fix: guard against null/empty files here too (consistent with the
    # same fix in list.sh). A null-type file has no keys to iterate; return
    # cleanly instead of crashing with "cannot get keys of !!null".
    local node_type
    node_type=$(yq 'type' "$vault_file" 2>/dev/null || echo "error")
    if [[ "$node_type" != "!!map" ]]; then
        return 0  # empty category — no keys to list, not an error
    fi
    yq 'keys | .[] | select(. != "sops")' "$vault_file"
}
