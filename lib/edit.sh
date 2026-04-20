#!/usr/bin/env bash
# edit.sh -- Edit a category file interactively via $EDITOR
# SOPS handles decrypt -> edit -> re-encrypt natively.
# Usage: coffer edit <category>
set -euo pipefail

cmd_edit() {
    local category="${1:-}"
    [[ -n "$category" ]] || die "Usage: coffer edit <category>"

    require_cmd sops
    # ensure_unlocked covers the "identity missing?" check, so a separate
    # require_identity call here would be redundant.
    ensure_unlocked

    # Verify EDITOR is set
    [[ -n "${EDITOR:-}" ]] || die "\$EDITOR is not set. Export it first: export EDITOR=vim"

    local vault_file="${COFFER_VAULT}/${category}.yaml"
    [[ -f "$vault_file" ]] || die "Category '${category}' not found. Available: $(list_categories | tr '\n' ' ')"

    # SOPS handles the full decrypt -> $EDITOR -> re-encrypt cycle.
    # It creates a temp file with restrictive permissions, opens the editor,
    # and re-encrypts on save. The temp file is securely deleted afterward.
    SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops "$vault_file" \
        || die "Failed to edit '${category}'"

    log "Saved ${category}"
}
