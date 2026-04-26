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
# VAULT REPO vs TOOL REPO:
# After the April 2026 vault/tool split, all git operations target COFFER_VAULT_ROOT
# (bryce-shashinka/coffer-vault) rather than COFFER_ROOT (1507-systems/coffer).
# COFFER_ROOT is only the tool code; COFFER_VAULT_ROOT is the data. Staging is
# restricted to vault/ and config/.sops.yaml -- never the whole working tree.
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

# auto_sync_pull
#
# Fetches and rebases the vault repo from origin/main BEFORE a vault write.
# This closes the drift window that caused the April 2026 push-rejection bug:
# if origin advanced between SessionStart and the current write (because the
# other machine pushed in the interim), a plain `coffer set` would commit
# locally and then fail with "non-fast-forward" on push.
#
# Walk:
#   1. Skip entirely if COFFER_AUTO_SYNC=0 (test / CI escape hatch).
#   2. Skip if the vault root is not a git repo (non-git vault setups).
#   3. Skip if no upstream is configured (fresh vault, no remote yet).
#   4. git fetch origin (quiet).
#   5. Check if behind: if local == origin, nothing to do.
#   6. Check for LOCAL commits not yet pushed (ahead of origin). Push them
#      first so the rebase has a clean base. This handles "prior session ended
#      before push completed" gracefully.
#   7. git pull --rebase origin main.
#      If the rebase produces conflicts (extremely rare on an encrypted vault —
#      conflicts in binary-style SOPS YAML are not auto-resolvable), we ABORT
#      and die() loudly. The write must not proceed on top of a broken state.
#   8. Log how many new commits arrived, if any.
#
# Returns:
#   0   -- success (vault is at or ahead of origin after the operation)
#   non-zero -- rebase conflict or unexpected git error (die() called)
auto_sync_pull() {
    # Escape hatch: operator or test harness wants no git ops.
    if [[ "${COFFER_AUTO_SYNC:-1}" == "0" ]]; then
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        # git unavailable: let the write proceed without a pre-pull. The push
        # step will catch the divergence later (and warn loudly).
        return 0
    fi

    local repo_root="${COFFER_VAULT_ROOT:-}"
    if [[ -z "$repo_root" ]]; then
        repo_root="${COFFER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    fi

    # Not a git repo: skip silently (preserves behavior for non-git vault setups).
    if [[ ! -d "${repo_root}/.git" ]]; then
        return 0
    fi

    # No upstream configured: nothing to pull from. This is normal for a
    # fresh vault before the first push, so warn rather than die.
    local upstream
    upstream=$(git -C "$repo_root" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "")
    if [[ -z "$upstream" ]]; then
        return 0
    fi

    # Fetch quietly. Network errors are non-fatal: a transient outage should
    # not block a write. We log a warning so the user knows origin wasn't reached.
    if ! git -C "$repo_root" fetch origin 2>/dev/null; then
        warn "auto-sync: fetch from origin failed (offline?) -- skipping pre-write pull"
        warn "  if origin has advanced, the push after write may be rejected"
        return 0
    fi

    # Check if there are local commits not yet on origin. If so, push them
    # first so that the rebase base (origin/main) includes our previous work.
    # This handles the "prior session ended before push completed" case.
    local ahead
    ahead=$(git -C "$repo_root" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    if [[ "$ahead" -gt 0 ]]; then
        log "auto-sync: ${ahead} local commit(s) not yet pushed; pushing before pull-rebase"
        local current_branch
        current_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        if [[ "$current_branch" == "main" ]]; then
            if ! git -C "$repo_root" push 2>/dev/null; then
                warn "auto-sync: push of unpushed local commits failed"
                warn "  continuing with pull-rebase; manual push may be needed"
            fi
        fi
    fi

    # Check how many commits we are behind origin after the fetch.
    local behind
    behind=$(git -C "$repo_root" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
    if [[ "$behind" -eq 0 ]]; then
        # Already up to date -- no rebase needed.
        return 0
    fi

    log "auto-sync: ${behind} commit(s) behind origin -- pulling before write"

    # Pull with rebase. --autostash is NOT used here intentionally: vault files
    # are SOPS-encrypted and any autostash pop that hits a conflict would produce
    # a corrupt or partially-merged encrypted file. Instead, we check for a dirty
    # working tree first and abort if one exists.
    local dirty
    dirty=$(git -C "$repo_root" status --porcelain -- config/.sops.yaml vault/ 2>/dev/null || echo "")
    if [[ -n "$dirty" ]]; then
        die "auto-sync: cannot pull before write -- vault has uncommitted local changes:
${dirty}
coffer:  Commit or reset these changes first (e.g., run 'coffer doctor' to inspect).
coffer:  Then retry your command."
    fi

    # Resolve which remote branch to pull from. We use the tracked upstream
    # (e.g., origin/main) and strip the remote prefix to get just the branch
    # name (e.g., "main"). This avoids hardcoding "main" and works correctly
    # even when the repo uses "master" or a custom default branch name.
    local remote_branch
    remote_branch=$(git -C "$repo_root" rev-parse --abbrev-ref '@{u}' 2>/dev/null \
        | sed 's|^[^/]*/||')
    # Fallback to "main" if we somehow can't derive it (belt-and-suspenders).
    remote_branch="${remote_branch:-main}"

    # Run the rebase. Capture output so we can surface it on failure.
    local pull_output
    if ! pull_output=$(git -C "$repo_root" pull --rebase origin "$remote_branch" 2>&1); then
        # Abort the in-progress rebase to leave the repo in a clean state.
        git -C "$repo_root" rebase --abort 2>/dev/null || true
        die "auto-sync: pull --rebase failed (conflict in encrypted vault?):
${pull_output}
coffer:  This requires manual resolution. Run:
coffer:    git -C ${repo_root} status
coffer:    git -C ${repo_root} rebase --abort   (if not already done)
coffer:  Then inspect the conflicting files and re-run your command."
    fi

    log "auto-sync: synced ${behind} commit(s) from origin before write"
    return 0
}

# auto_sync_push <commit-message>
#
# Stages ONLY config/.sops.yaml and vault/ in the VAULT REPO (never the whole
# working tree or any tool-repo files), commits if anything changed, and pushes
# to the current upstream.
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
        log "auto-sync: COFFER_AUTO_SYNC=0 -- skipping git commit+push"
        return 0
    fi

    # We need git to be available (it nearly always is on supported machines,
    # but better to check than to produce a cryptic error).
    if ! command -v git >/dev/null 2>&1; then
        warn "auto-sync: git not found on PATH -- skipping commit+push"
        warn "  resolve manually: cd ${COFFER_VAULT_ROOT} && git status && git push"
        return 0
    fi

    # All git operations target the vault repo, NOT the tool repo. The vault
    # repo is what changes when secrets are written; the tool repo changes only
    # when the tool code is updated via a normal PR workflow.
    local repo_root="${COFFER_VAULT_ROOT:-}"
    if [[ -z "$repo_root" ]]; then
        # COFFER_VAULT_ROOT is set by bin/coffer before sourcing this file.
        # If it is somehow absent (e.g., this file was sourced directly), fall
        # back to deriving it from COFFER_ROOT for backward compat.
        repo_root="${COFFER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
        warn "auto-sync: COFFER_VAULT_ROOT not set, falling back to ${repo_root}"
    fi

    # Check branch: auto-push only on main. Any other branch commits locally
    # only (preserves history without polluting unintended remote branches).
    local current_branch
    current_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    if [[ "$current_branch" != "main" ]]; then
        warn "auto-sync: current branch is '${current_branch}', not 'main' -- committing locally but NOT pushing"
        warn "  switch to main and push manually when ready: git push origin main"
    fi

    # Stage ONLY the files that coffer manages in the vault repo. Deliberately
    # NOT `git add -A`: that would pick up unrelated working-tree changes and
    # pollute the auto-commit with unintended content.

    # Stage config/.sops.yaml (recipient list changes from add-recipient / finalize-onboard)
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

    log "auto-sync: committed -- ${commit_message}"

    # Push only when on main.
    if [[ "$current_branch" == "main" ]]; then
        local upstream
        upstream=$(git -C "$repo_root" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "")
        if [[ -z "$upstream" ]]; then
            warn "auto-sync: no upstream configured -- commit saved locally but not pushed"
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
