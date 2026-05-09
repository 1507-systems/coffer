#!/usr/bin/env bash
# delete.sh -- Remove a key from an encrypted vault category file
# Usage: coffer delete <category/key> [-y | --yes]
#
# Atomically decrypts the category file, removes the key, re-encrypts, and
# (via auto_sync_push in the dispatcher) commits the result. If the key is
# absent the command exits non-zero rather than silently succeeding. A
# confirmation prompt is shown by default; pass -y/--yes to skip it.
set -euo pipefail

cmd_delete() {
    local path=""
    local skip_confirm=false

    # Parse arguments. Flags may appear before or after the path.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) skip_confirm=true; shift ;;
            -*) die "Unknown flag: $1. Usage: coffer delete <category/key> [-y|--yes]" ;;
            *)
                if [[ -z "$path" ]]; then
                    path="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$path" ]] || die "Usage: coffer delete <category/key> [-y|--yes]"

    require_cmd sops
    require_cmd jq
    # ensure_unlocked handles the "identity missing?" check and loads the age key
    # into SOPS_AGE_KEY if not already set. A separate require_identity call is
    # not needed -- it would duplicate the same stat() calls.
    ensure_unlocked
    parse_path "$path"

    # Fail loudly if the category file does not exist at all.
    [[ -f "$COFFER_VAULT_FILE" ]] \
        || die "Category '${COFFER_CATEGORY}' not found. Available: $(list_categories | tr '\n' ' ')"

    local sops_config="${COFFER_SOPS_CONFIG}"
    [[ -f "$sops_config" ]] || die "SOPS config not found at ${sops_config}. Run: coffer init"

    # Decrypt the category to JSON so we can use jq for key inspection and
    # removal. We use JSON (not raw YAML) to avoid yq parsing issues with
    # special characters in values (%, !, $, etc.).
    local decrypted
    decrypted=$(SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops decrypt --output-type json "$COFFER_VAULT_FILE" \
        2>&1) \
        || die "Failed to decrypt '${COFFER_CATEGORY}': ${decrypted}"

    # Verify the key exists before asking the user to confirm and before any
    # mutation. Exit non-zero so callers and scripts can distinguish "key
    # absent" from a successful delete.
    local key_exists
    key_exists=$(printf '%s' "$decrypted" \
        | jq --arg key "$COFFER_KEY" 'has($key)') \
        || die "Failed to inspect keys in '${COFFER_CATEGORY}'"

    if [[ "$key_exists" != "true" ]]; then
        die "Key '${COFFER_KEY}' not found in '${COFFER_CATEGORY}'"
    fi

    # Confirmation prompt (skipped with -y/--yes). This is a destructive
    # operation: the encrypted blob is unrecoverable from the vault after
    # delete + push (git history retains it, but users may not expect that).
    #
    # We require the user to retype the full category/key path rather than a
    # single y/N keystroke. A retype prompt forces the user to read what they
    # are about to destroy -- a muscle-memory `y` after a mistyped path is
    # exactly the failure mode this command must defend against. Bypass with
    # -y/--yes for scripted use (CI, batch decommission, etc.).
    if [[ "$skip_confirm" == false ]]; then
        printf 'About to delete: %s\n' "$path" >&2
        printf 'Retype the full path to confirm (or anything else to abort): ' >&2
        local typed
        IFS= read -r typed
        if [[ "$typed" != "$path" ]]; then
            # Use return instead of exit: delete.sh is sourced (not run in a
            # subshell), so exit 0 here would kill the calling shell session.
            log "Aborted (path mismatch -- nothing deleted)."
            return 0
        fi
    fi

    # Remove the key from the decrypted JSON, then re-encrypt back to YAML.
    # We use --filename-override so SOPS matches the destination vault file
    # path against creation_rules in .sops.yaml, which preserves all
    # authorized recipients. Passing --age directly would drop every other
    # recipient and is intentionally NOT done here (same reasoning as set.sh).
    local updated
    updated=$(printf '%s' "$decrypted" \
        | jq --arg key "$COFFER_KEY" 'del(.[$key])') \
        || die "Failed to remove key '${COFFER_KEY}' from decrypted '${COFFER_CATEGORY}'"

    # shellcheck disable=SC2094
    # SC2094: --filename-override is a path string for .sops.yaml lookup;
    # SOPS never reads the vault file from stdin here.
    printf '%s' "$updated" \
        | SOPS_AGE_KEY="${SOPS_AGE_KEY}" SOPS_CONFIG="$sops_config" sops encrypt \
            --filename-override "$COFFER_VAULT_FILE" \
            --input-type json --output-type yaml \
            /dev/stdin > "$COFFER_VAULT_FILE" \
        || die "Failed to re-encrypt '${COFFER_CATEGORY}' after deleting '${COFFER_KEY}'"

    log "Deleted ${path}"
}
