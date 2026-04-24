#!/usr/bin/env bash
# git-sync.sh -- Auto-commit-and-push helper for coffer state-modifying commands
#
# WHY THIS EXISTS:
# The April 2026 .sops.yaml/vault drift bug was caused by Mutagen syncing file
# *content* between Wiles and Verve without syncing git state. A machine could
# have all the right bytes on disk but be N commits behind origin/main, so the
# next `coffer set` on that machine re-encrypted with a stale recipient list.
#
# The fix: every command that changes vault state also immediately commits and
# pushes. Origin/main becomes the authoritative truth that both machines can
# pull from, independent of Mutagen's eventual-consistency timing.
#
# ESCAPE HATCH:
# Set COFFER_AUTO_SYNC=0 in the environment to skip git operations entirely.
# This is designed for CI runs, test sandboxes, and one-shot automation where
# you don't want git noise. Default is enabled (auto-sync on).
#
# BRANCH SAFETY:
# Auto-push is skipped when the current branch is not 'main'. Writes on a
# feature branch are committed locally (so history is preserved) but not pushed,
# to avoid polluting non-main remote branches with auto-commits.
#
# Sourced by bin/coffer (after common.sh) when called by a state-modifying
# command. Never executed directly.
set -euo pipefail

# auto_sync_push <commit-message>
#
# Stages ONLY config/.sops.yaml and vault/ (never the whole working tree),
# commits if anything changed, and pushes to the current upstream.
#
# Arguments:
#   $1  -- short description of what changed; prepended with "coffer: " to
#           form the full commit message (e.g., "set hicv/portal-password")
#
# Returns:
#   0   -- success (or nothing-to-sync, or COFFER_AUTO_SYNC=0)
#   non-zero -- push/commit failed (logged with remediation hint; the on-disk
#               write is NOT rolled back since that would be worse than the
#               inconsistency)
auto_sync_push() {
    local short_message="${1:-vault change}"

    # Escape hatch: operator or test harness wants no git ops.
    if [[ "${COFFER_AUTO_SYNC:-1}" == "0" ]]; then
        log "auto-sync: COFFER_AUTO_SYNC=0 — skipping git commit+push"
        return 0
    fi

    # We need git to be available (it nearly always is on supported machines,
    # but better to check than to produce a cryptic error).
    if ! command -v git >/dev/null 2>&1; then
        warn "auto-sync: git not found on PATH — skipping commit+push"
        warn "  resolve manually: cd ${COFFER_ROOT} && git status && git push"
        return 0
    fi

    # Resolve the coffer repo root. COFFER_ROOT is set by bin/coffer; fall back
    # to deriving it from this file's location for robustness.
    local repo_root="${COFFER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

    # Check branch: auto-push only on main. Any other branch commits locally
    # only (preserves history without polluting unintended remote branches).
    local current_branch
    current_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    if [[ "$current_branch" != "main" ]]; then
        warn "auto-sync: current branch is '${current_branch}', not 'main' — committing locally but NOT pushing"
        warn "  switch to main and push manually when ready: git push origin main"
    fi

    # Stage ONLY the files that coffer manages. Deliberately NOT `git add -A`:
    # that would pick up unrelated working-tree changes (e.g., a half-edited
    # SPEC.md) and pollute the auto-commit with unintended content.

    # Stage .sops.yaml (recipient list changes from add-recipient / finalize-onboard)
    local sops_config="${repo_root}/config/.sops.yaml"
    if [[ -f "$sops_config" ]]; then
        git -C "$repo_root" add "$sops_config" 2>/dev/null || true
    fi

    # Stage vault/ (encrypted secret changes from set / edit / import)
    local vault_dir="${COFFER_VAULT:-${repo_root}/vault}"
    if [[ -d "$vault_dir" ]]; then
        git -C "$repo_root" add "$vault_dir" 2>/dev/null || true
    fi

    # Check if staging actually produced any diff vs HEAD. `git diff --cached
    # --quiet` exits 0 when there's nothing staged, 1 when there are changes.
    if git -C "$repo_root" diff --cached --quiet 2>/dev/null; then
        log "auto-sync: nothing to sync (no changes in config/.sops.yaml or vault/)"
        return 0
    fi

    # Commit. The message follows conventional-commits style with a "coffer:"
    # prefix so auto-commits are easy to spot in git log.
    local commit_message="coffer: ${short_message}"
    if ! git -C "$repo_root" commit -m "$commit_message" 2>/dev/null; then
        warn "auto-sync: git commit failed for '${commit_message}'"
        warn "  resolve manually: cd ${repo_root} && git status && git push"
        return 1
    fi

    log "auto-sync: committed — ${commit_message}"

    # Push only when on main.
    if [[ "$current_branch" == "main" ]]; then
        local upstream
        upstream=$(git -C "$repo_root" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "")
        if [[ -z "$upstream" ]]; then
            warn "auto-sync: no upstream configured — commit saved locally but not pushed"
            warn "  resolve manually: cd ${repo_root} && git push -u origin main"
            return 0
        fi

        if ! git -C "$repo_root" push 2>/dev/null; then
            warn "auto-sync: git push failed"
            warn "  resolve manually: cd ${repo_root} && git status && git push"
            # Return non-zero to surface the problem, but the on-disk write
            # already happened and must NOT be rolled back. The user can push
            # manually once they resolve the conflict/auth issue.
            return 1
        fi

        log "auto-sync: pushed to ${upstream}"
    fi

    return 0
}
