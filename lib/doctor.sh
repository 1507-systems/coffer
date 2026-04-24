#!/usr/bin/env bash
# doctor.sh -- Read-only vault state audit for coffer
#
# WHY THIS EXISTS:
# The April 2026 drift bug (Verve ran add-recipient, which re-encrypted vault
# files with 3 recipients via sops updatekeys, but never committed/pushed
# .sops.yaml, leaving Wiles's git-tracked config at 2 recipients) was invisible
# until a write operation failed. `coffer doctor` surfaces drift proactively:
# it compares each vault file's embedded recipient list against the canonical
# list in config/.sops.yaml and reports any mismatch before it causes a lockout.
#
# Usage:  coffer doctor
# Exit:   0 if all checks pass, 1 if any drift or problem is found.
# Output: One status line per check. Machine-parseable (prefix [OK] or [DRIFT]).
#         Color-coded when stdout is a TTY.
set -euo pipefail

# --- Color helpers ---
# Only use ANSI codes when connected to a real terminal. Scripts, CI, and
# non-interactive captures get plain ASCII so they're diff/grep-friendly.

_color_ok()    { if [[ -t 1 ]]; then printf '\033[0;32m%s\033[0m' "$*"; else printf '%s' "$*"; fi; }
_color_drift() { if [[ -t 1 ]]; then printf '\033[0;31m%s\033[0m' "$*"; else printf '%s' "$*"; fi; }
_color_warn()  { if [[ -t 1 ]]; then printf '\033[0;33m%s\033[0m' "$*"; else printf '%s' "$*"; fi; }

_line_ok()    { printf '%s %s\n' "$(_color_ok    '[OK]')"    "$*"; }
_line_drift() { printf '%s %s\n' "$(_color_drift '[DRIFT]')" "$*"; }

# --- Recipient parsing helpers ---

# Parse the canonical age recipient list from config/.sops.yaml.
# The file has the structure:
#   creation_rules:
#     - path_regex: vault/.*\.yaml$
#       age: >-
#         key1,key2,key3
#
# The >- block may wrap across lines; yq normalizes it. We fall back to a
# grep-based approach if yq is unavailable so doctor can run even on a
# partially-bootstrapped machine.
#
# Prints one key per line on stdout.
parse_sops_yaml_recipients() {
    local sops_config="$1"
    require_cmd yq

    # yq expression: grab the first creation_rules entry's age field and split
    # on commas. The >- folded scalar collapses newlines, so the value is a
    # single comma-separated string. We split on comma+optional-whitespace.
    local age_value
    age_value=$(yq '.creation_rules[0].age' "$sops_config" 2>/dev/null || echo "")

    if [[ -z "$age_value" ]] || [[ "$age_value" == "null" ]]; then
        return 1  # caller treats empty list as a drift condition
    fi

    # Split comma-separated list; trim whitespace around each key.
    # Works even if the YAML was hand-edited with inconsistent spacing.
    #
    # NOTE: `printf '%s'` does not add a trailing newline, so the last token
    # after `tr ',' '\n'` has no trailing newline. `while IFS= read -r` exits
    # non-zero on the last line if it lacks a newline terminator, so we use
    # `|| [[ -n "$key" ]]` to process that final partial line as well.
    printf '%s\n' "$age_value" | tr ',' '\n' | while IFS= read -r key || [[ -n "$key" ]]; do
        # Strip leading/trailing whitespace from each key.
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ -n "$key" ]] && printf '%s\n' "$key"
    done
}

# Parse the recipient list embedded in a SOPS-encrypted vault file.
# The sops block in the YAML has the structure:
#   sops:
#     age:
#       - recipient: age1xxx
#         enc: |
#           ...
#
# Prints one key per line on stdout.
parse_vault_file_recipients() {
    local vault_file="$1"
    require_cmd yq

    # yq expression: descend into sops.age array, pick the recipient field.
    # Returns "" if the file has no sops.age block (unencrypted files).
    yq '.sops.age[].recipient // ""' "$vault_file" 2>/dev/null | grep -v '^$' || true
}

# Check whether two newline-separated key lists are equal as sets.
# Prints "MATCH" or "MISSING:<key>" / "EXTRA:<key>" lines.
# Returns 0 if match, 1 if any difference.
compare_recipient_sets() {
    local canonical_list="$1"  # newline-separated
    local file_list="$2"        # newline-separated

    local any_diff=0

    # Check each canonical key appears in the file
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if ! printf '%s\n' "$file_list" | grep -qF "$key"; then
            printf 'MISSING:%s\n' "$key"
            any_diff=1
        fi
    done <<< "$canonical_list"

    # Check each file key exists in canonical (detect extra/stale recipients)
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if ! printf '%s\n' "$canonical_list" | grep -qF "$key"; then
            printf 'EXTRA:%s\n' "$key"
            any_diff=1
        fi
    done <<< "$file_list"

    return $any_diff
}

# Truncate an age pubkey for display: show age1 prefix + first 8 chars + ...
# This keeps output scannable without blowing up terminal width.
_abbrev_key() {
    local key="$1"
    if [[ ${#key} -gt 16 ]]; then
        printf '%s...' "${key:0:16}"
    else
        printf '%s' "$key"
    fi
}

# --- Main doctor command ---

cmd_doctor() {
    require_cmd yq

    local sops_config="${COFFER_SOPS_CONFIG}"
    local vault_dir="${COFFER_VAULT}"
    local config_dir="${COFFER_CONFIG_DIR}"
    local repo_root="${COFFER_ROOT}"

    local issues=0  # count of DRIFT lines emitted

    echo "coffer doctor"

    # --- Check 1: .sops.yaml readable and has recipients ---
    if [[ ! -f "$sops_config" ]]; then
        _line_drift ".sops.yaml not found at ${sops_config} — run: coffer init"
        issues=$((issues + 1))
        # Without .sops.yaml we can't run any other checks meaningfully.
        echo ""
        _summary "$issues"
        return 1
    fi

    local canonical_recipients
    canonical_recipients=$(parse_sops_yaml_recipients "$sops_config" 2>/dev/null || echo "")

    if [[ -z "$canonical_recipients" ]]; then
        _line_drift ".sops.yaml: could not parse age recipients (file may be malformed)"
        issues=$((issues + 1))
        echo ""
        _summary "$issues"
        return 1
    fi

    local recipient_count
    recipient_count=$(printf '%s\n' "$canonical_recipients" | grep -c '.' || echo 0)

    # Build a short display list of abbreviated keys.
    # Pure bash join to avoid BSD paste's stdin limitation (paste -sd requires
    # a file argument on macOS, unlike GNU paste which accepts stdin).
    local abbrev_list=""
    while IFS= read -r k; do
        local abbrev
        abbrev=$(_abbrev_key "$k")
        if [[ -z "$abbrev_list" ]]; then
            abbrev_list="$abbrev"
        else
            abbrev_list="${abbrev_list}, ${abbrev}"
        fi
    done <<< "$canonical_recipients"
    _line_ok ".sops.yaml: ${recipient_count} recipient(s) (${abbrev_list})"

    # --- Check 2: Identity consistency ---
    # This machine's pubkey must appear in the canonical recipient list.
    local pubkey_file="${config_dir}/public-key"
    if [[ ! -f "$pubkey_file" ]]; then
        _line_drift "Identity: ~/.config/coffer/public-key not found — run: coffer init"
        issues=$((issues + 1))
    else
        local my_pubkey
        my_pubkey=$(< "$pubkey_file")
        # Strip whitespace
        my_pubkey="${my_pubkey#"${my_pubkey%%[![:space:]]*}"}"
        my_pubkey="${my_pubkey%"${my_pubkey##*[![:space:]]}"}"

        local machine_name="(unknown)"
        if [[ -f "${config_dir}/machine-name" ]]; then
            machine_name=$(< "${config_dir}/machine-name")
            machine_name="${machine_name#"${machine_name%%[![:space:]]*}"}"
            machine_name="${machine_name%"${machine_name##*[![:space:]]}"}"
        fi

        if printf '%s\n' "$canonical_recipients" | grep -qF "$my_pubkey"; then
            _line_ok "Identity: $(_abbrev_key "$my_pubkey") is in recipient list (machine: ${machine_name})"
        else
            _line_drift "Identity: $(_abbrev_key "$my_pubkey") (machine: ${machine_name}) NOT in .sops.yaml recipient list"
            _line_drift "         This machine cannot decrypt vault files encrypted after the last add-recipient."
            _line_drift "         Run 'coffer finalize-onboard' on a trusted machine to fix this."
            issues=$((issues + 1))
        fi
    fi

    # --- Check 3: Git state ---
    # Drift can accumulate when git state diverges between machines (Mutagen
    # syncs bytes but not commits). We report branch, ahead/behind, and dirty
    # working tree — all three signal risk of drift.
    if command -v git >/dev/null 2>&1 && [[ -d "${repo_root}/.git" ]]; then
        # `git rev-parse --abbrev-ref HEAD` outputs to stdout (not stderr)
        # and exits 128 on a fresh repo with no commits, causing "HEAD\nunknown"
        # when combined with `|| echo unknown`. Redirect both stdout and stderr
        # to suppress any output on failure; then emit our own fallback.
        local branch
        branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="unknown"

        # Fetch quietly to get an accurate ahead/behind count. Suppress output
        # and ignore errors (no network = still useful local checks).
        git -C "$repo_root" fetch origin 2>/dev/null || true

        local ahead=0 behind=0
        ahead=$(git -C "$repo_root" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
        behind=$(git -C "$repo_root" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)

        # Uncommitted changes to coffer-managed files specifically (not ALL files,
        # because unrelated changes shouldn't alarm the doctor).
        local dirty_lines
        dirty_lines=$(git -C "$repo_root" status --porcelain \
            -- config/.sops.yaml vault/ 2>/dev/null || echo "")

        local git_ok=true

        if [[ "$branch" != "main" ]]; then
            _line_drift "Git: on branch '${branch}' (not main) — auto-push is disabled on feature branches"
            issues=$((issues + 1))
            git_ok=false
        fi

        if [[ "$behind" -gt 0 ]]; then
            _line_drift "Git: ${behind} commit(s) behind origin/${branch} — run 'git pull'"
            issues=$((issues + 1))
            git_ok=false
        fi

        if [[ "$ahead" -gt 0 ]]; then
            # Ahead is informational (not a drift risk by itself) but worth noting.
            _line_drift "Git: ${ahead} commit(s) ahead of origin/${branch} (not yet pushed)"
            issues=$((issues + 1))
            git_ok=false
        fi

        if [[ -n "$dirty_lines" ]]; then
            _line_drift "Git: uncommitted changes in coffer-managed paths:"
            while IFS= read -r dline; do
                _line_drift "     ${dline}"
            done <<< "$dirty_lines"
            issues=$((issues + 1))
            git_ok=false
        fi

        if [[ "$git_ok" == "true" ]]; then
            _line_ok "Git: on main, up to date with origin/main, working tree clean"
        fi
    else
        _line_ok "Git: (skipped — not a git repo or git unavailable)"
    fi

    # --- Check 4: Vault file recipient drift ---
    # For each encrypted vault file, compare its embedded recipient list to the
    # canonical list. Any mismatch means a sops updatekeys ran with a different
    # .sops.yaml than what is currently on disk — the root cause of the bug.
    if [[ ! -d "$vault_dir" ]]; then
        _line_drift "Vault directory not found at ${vault_dir}"
        issues=$((issues + 1))
    else
        local total_checked=0
        local total_drifted=0
        local total_skipped=0

        for vault_file in "${vault_dir}"/*.yaml; do
            local filename
            filename=$(basename "$vault_file")

            # Skip files with no sops metadata: they are either empty category
            # placeholders (github.yaml = 0 bytes) or unencrypted stubs. These
            # have no recipient list to check.
            if ! grep -q '^sops:' "$vault_file" 2>/dev/null; then
                total_skipped=$((total_skipped + 1))
                continue
            fi

            total_checked=$((total_checked + 1))

            local file_recipients
            file_recipients=$(parse_vault_file_recipients "$vault_file" 2>/dev/null || echo "")

            if [[ -z "$file_recipients" ]]; then
                _line_drift "vault/${filename}: could not parse sops.age recipients (file may be corrupted)"
                total_drifted=$((total_drifted + 1))
                issues=$((issues + 1))
                continue
            fi

            local file_count
            file_count=$(printf '%s\n' "$file_recipients" | grep -c '.' || echo 0)

            # Compare sets in both directions.
            local diff_output
            diff_output=$(compare_recipient_sets "$canonical_recipients" "$file_recipients" 2>/dev/null || true)

            if [[ -z "$diff_output" ]]; then
                # All good for this file. We don't print per-file OK lines
                # when all files pass to keep output compact (they're covered
                # by the summary line). Individual DRIFT lines stand out more
                # when the surrounding noise is removed.
                :
            else
                local missing_keys extra_keys
                missing_keys=$(printf '%s\n' "$diff_output" | grep '^MISSING:' | sed 's/^MISSING://' || true)
                extra_keys=$(printf '%s\n' "$diff_output" | grep '^EXTRA:' | sed 's/^EXTRA://' || true)

                local detail=""
                if [[ -n "$missing_keys" ]]; then
                    # BSD paste requires a file arg (not stdin) with -s on macOS,
                    # so we join with a pure bash loop instead of paste -sd.
                    local abbrev_missing=""
                    while IFS= read -r k; do
                        local _am
                        _am=$(_abbrev_key "$k")
                        if [[ -z "$abbrev_missing" ]]; then abbrev_missing="$_am"
                        else abbrev_missing="${abbrev_missing}, ${_am}"; fi
                    done <<< "$missing_keys"
                    detail="${detail}missing ${abbrev_missing}"
                fi
                if [[ -n "$extra_keys" ]]; then
                    local abbrev_extra=""
                    while IFS= read -r k; do
                        local _ae
                        _ae=$(_abbrev_key "$k")
                        if [[ -z "$abbrev_extra" ]]; then abbrev_extra="$_ae"
                        else abbrev_extra="${abbrev_extra}, ${_ae}"; fi
                    done <<< "$extra_keys"
                    [[ -n "$detail" ]] && detail="${detail}; "
                    detail="${detail}extra ${abbrev_extra}"
                fi

                _line_drift "vault/${filename}: ${file_count} recipient(s) in file vs ${recipient_count} in .sops.yaml (${detail})"
                total_drifted=$((total_drifted + 1))
                issues=$((issues + 1))
            fi
        done

        if [[ $total_drifted -eq 0 ]] && [[ $total_checked -gt 0 ]]; then
            _line_ok "Vault files: ${total_checked} checked, ${total_checked} match .sops.yaml, ${total_skipped} skipped (unencrypted)"
        elif [[ $total_checked -eq 0 ]] && [[ $total_skipped -gt 0 ]]; then
            _line_ok "Vault files: ${total_skipped} skipped (all unencrypted — nothing to check)"
        elif [[ $total_checked -eq 0 ]]; then
            _line_ok "Vault files: no yaml files found in ${vault_dir}"
        else
            _line_drift "Vault files: ${total_checked} checked, ${total_drifted} drifted, ${total_skipped} skipped (unencrypted)"
        fi
    fi

    # --- Summary footer ---
    echo ""
    _summary "$issues"
    [[ "$issues" -eq 0 ]] && return 0 || return 1
}

# Print the summary line and exit-code hint.
_summary() {
    local issues="$1"
    if [[ "$issues" -eq 0 ]]; then
        printf '%s\n' "$(_color_ok 'coffer doctor: all checks passed')"
    else
        printf '%s\n' "$(_color_drift "coffer doctor: ${issues} issue(s) found")"
    fi
}

# --- Lightweight preflight check for write commands ---
#
# Called by cmd_set and cmd_edit BEFORE the write happens. Samples a single
# non-empty vault file and compares its recipient list to .sops.yaml. If they
# differ, the write is aborted with a clear error pointing to `coffer doctor`.
#
# This is intentionally lightweight (one file, not all files) because it runs
# on every write. The full doctor command is available for thorough audits.
#
# Returns 0 (ok to write) or calls die() (abort write).
preflight_recipient_check() {
    local sops_config="${COFFER_SOPS_CONFIG}"
    local vault_dir="${COFFER_VAULT}"

    # If .sops.yaml doesn't exist this is a fresh init and there's nothing to
    # drift against. The write will fail on its own if sops can't find the config.
    [[ -f "$sops_config" ]] || return 0

    # If yq isn't available we can't parse recipients — skip the check rather
    # than blocking all writes on a tool that isn't strictly required for set.
    command -v yq >/dev/null 2>&1 || return 0

    # Find a sample vault file that has sops metadata.
    local sample_file=""
    if [[ -d "$vault_dir" ]]; then
        for f in "${vault_dir}"/*.yaml; do
            if grep -q '^sops:' "$f" 2>/dev/null; then
                sample_file="$f"
                break
            fi
        done
    fi

    # No encrypted files yet (fresh vault) — nothing to compare against.
    [[ -n "$sample_file" ]] || return 0

    # Parse both lists.
    local canonical_recipients
    canonical_recipients=$(parse_sops_yaml_recipients "$sops_config" 2>/dev/null || echo "")
    [[ -n "$canonical_recipients" ]] || return 0  # can't parse — let write proceed

    local file_recipients
    file_recipients=$(parse_vault_file_recipients "$sample_file" 2>/dev/null || echo "")
    [[ -n "$file_recipients" ]] || return 0  # can't parse — let write proceed

    # Compare. If compare_recipient_sets exits non-zero, there is drift.
    local diff_output
    diff_output=$(compare_recipient_sets "$canonical_recipients" "$file_recipients" 2>/dev/null || true)

    if [[ -n "$diff_output" ]]; then
        die "vault state is inconsistent (.sops.yaml does not match vault file metadata in $(basename "$sample_file"))
coffer:        Run 'coffer doctor' to see details and 'coffer add-recipient <key>' or
coffer:        'coffer finalize-onboard' to reconcile before writing."
    fi

    return 0
}
