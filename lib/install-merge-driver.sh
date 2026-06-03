#!/usr/bin/env bash
# install-merge-driver.sh -- Register the coffer SOPS merge driver per machine
#
# WHY THIS EXISTS:
# git custom merge drivers are configured in two halves:
#   1. `.gitattributes` (committed, travels with the repo) routes paths to a
#      NAMED driver.
#   2. `merge.<name>.driver` in `.git/config` (per-clone, NEVER cloned/fetched)
#      defines what that name actually runs.
# Because half 2 is not transmitted by clone/fetch/pull, a `.gitattributes` that
# names a driver the local `.git/config` doesn't define makes git SILENTLY fall
# back to the default text merge -- i.e. the exact ciphertext-conflict failure we
# are trying to fix. So the driver definition must be installed PER MACHINE.
#
# `coffer install-merge-driver` does, idempotently, in COFFER_VAULT_ROOT:
#   1. git config merge.coffer-sops.driver/.name  (the union driver, §3)
#   2. ensure `.gitattributes` routes vault/** -> coffer-sops AND explicitly
#      pins config/.sops.yaml -> the DEFAULT driver (recipient changes must NOT
#      be unioned -- they conflict loudly or fast-forward, never silently merge).
#   3. stage + commit `.gitattributes` if it changed, then push (on main).
#
# The driver command uses the ABSOLUTE path to this clone's bin/coffer, because
# git runs merge drivers in a minimal non-interactive shell where `coffer` may
# not be on PATH. .git/config is per-clone anyway, so a machine-specific
# absolute path there is correct.
#
# Sourced by bin/coffer; never executed directly.
set -euo pipefail

# The .gitattributes lines coffer manages. vault/** routes through the union
# driver; config/.sops.yaml is pinned to git's built-in driver (`merge=binary`
# would mark it conflicted unconditionally; `-merge`/default lets a one-sided
# change fast-forward and a true divergence conflict -- which is what we want:
# never silently union recipients). We deliberately do NOT register a custom
# recipients driver in v1 (plan §4.1): the default merge already conflicts loudly
# on true recipient divergence, which is the required behavior.
_COFFER_GA_VAULT_LINE='vault/** merge=coffer-sops'
_COFFER_GA_SOPS_LINE='config/.sops.yaml -merge'

cmd_install_merge_driver() {
    require_cmd git

    local repo_root="${COFFER_VAULT_ROOT:-}"
    [[ -n "$repo_root" ]] || die "COFFER_VAULT_ROOT is not set; cannot install merge driver"
    [[ -d "${repo_root}/.git" ]] || die "Vault root '${repo_root}' is not a git repo; cannot install merge driver"

    # Absolute path to THIS clone's coffer binary. ${COFFER_ROOT}/bin/coffer is
    # the tool repo's entrypoint (COFFER_ROOT is exported by bin/coffer).
    local coffer_bin="${COFFER_ROOT}/bin/coffer"
    if [[ ! -x "$coffer_bin" ]]; then
        # Fall back to resolving relative to this lib file (covers sourced-in-test
        # contexts where COFFER_ROOT may point at a sandbox).
        coffer_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" 2>/dev/null && pwd)/coffer"
    fi
    [[ -x "$coffer_bin" ]] || die "Could not locate an executable coffer binary to register as the merge driver (looked at ${COFFER_ROOT}/bin/coffer)"

    # --- 1. Register the per-clone driver definition ---
    # The %O %A %B %L %P placeholders are substituted by git at merge time.
    local driver_cmd="'${coffer_bin}' merge-driver %O %A %B %L %P"
    git -C "$repo_root" config "merge.coffer-sops.name" \
        "coffer SOPS-aware union merge of encrypted vault category files"
    git -C "$repo_root" config "merge.coffer-sops.driver" "$driver_cmd"
    log "install-merge-driver: registered merge.coffer-sops -> ${coffer_bin} merge-driver"

    # --- 2. Ensure .gitattributes routes the right paths ---
    local ga_file="${repo_root}/.gitattributes"
    local changed=0

    # Append each managed line only if an equivalent routing isn't already present.
    # We match on the path token so a hand-edited variant isn't duplicated.
    if ! grep -Eq '^[[:space:]]*vault/\*\*[[:space:]]+merge=coffer-sops([[:space:]]|$)' "$ga_file" 2>/dev/null; then
        printf '%s\n' "$_COFFER_GA_VAULT_LINE" >> "$ga_file"
        changed=1
    fi
    if ! grep -Eq '^[[:space:]]*config/\.sops\.yaml[[:space:]]' "$ga_file" 2>/dev/null; then
        printf '%s\n' "$_COFFER_GA_SOPS_LINE" >> "$ga_file"
        changed=1
    fi

    if [[ "$changed" -eq 1 ]]; then
        log "install-merge-driver: wrote routing lines to ${ga_file}"
    else
        log "install-merge-driver: .gitattributes already has the coffer routing lines"
    fi

    # --- 3. Commit & push .gitattributes if it changed in the index ---
    # Escape hatch + branch safety mirror auto_sync_push.
    if [[ "${COFFER_AUTO_SYNC:-1}" == "0" ]]; then
        log "install-merge-driver: COFFER_AUTO_SYNC=0 -- not committing .gitattributes (staged on disk only)"
        return 0
    fi

    git -C "$repo_root" add "$ga_file" 2>/dev/null || true
    if git -C "$repo_root" diff --cached --quiet -- "$ga_file" 2>/dev/null; then
        log "install-merge-driver: .gitattributes already committed; nothing to push"
        return 0
    fi

    local current_branch
    current_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    if ! git -C "$repo_root" commit -m "coffer: install SOPS merge driver routing (.gitattributes)" 2>/dev/null; then
        warn "install-merge-driver: commit of .gitattributes failed"
        warn "  resolve manually: cd ${repo_root} && git status && git add .gitattributes && git commit"
        return 1
    fi
    log "install-merge-driver: committed .gitattributes"

    if [[ "$current_branch" == "main" ]]; then
        local upstream
        upstream=$(git -C "$repo_root" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "")
        if [[ -z "$upstream" ]]; then
            warn "install-merge-driver: no upstream configured -- .gitattributes committed locally but not pushed"
            return 0
        fi
        if ! git -C "$repo_root" push 2>/dev/null; then
            warn "install-merge-driver: push of .gitattributes failed"
            warn "  resolve manually: cd ${repo_root} && git push"
            return 1
        fi
        log "install-merge-driver: pushed .gitattributes to ${upstream}"
    else
        warn "install-merge-driver: current branch is '${current_branch}', not 'main' -- committed locally but NOT pushed"
    fi

    return 0
}
