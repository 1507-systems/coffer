#!/usr/bin/env bash
# unlock.sh -- Load the age secret key from the session-key file and print
# an `export SOPS_AGE_KEY=...` line suitable for `eval $(coffer unlock)`.
#
# Since the April 2026 refactor, coffer's identity lives entirely in the
# session-key file at ${COFFER_SESSION_KEY}. `coffer unlock` is now a thin
# convenience: it reads the file and emits the export statement so the user
# can load the key into their current shell in one step. There is no Keychain
# path anymore — if the file is missing, unlock tells the user to run
# `coffer init`.
#
# Usage:
#   eval $(coffer unlock)          # loads SOPS_AGE_KEY into current shell
#   coffer unlock --auto           # no-op (retained for backward compatibility
#                                  # with LaunchAgent configs; prints an info
#                                  # message explaining the new model)
set -euo pipefail

cmd_unlock() {
    # --- Argument parsing ---
    # --auto is retained as a documented no-op because an older LaunchAgent
    # recipe (see SPEC.md history) may still invoke it. Silently succeeding
    # with an informational log avoids breaking those installations; the
    # operator can remove the LaunchAgent at their convenience.
    local auto=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) auto=true; shift ;;
            -h|--help)
                cat >&2 <<'EOF'
Usage: coffer unlock [--auto]

Prints `export SOPS_AGE_KEY=...` for use with `eval $(coffer unlock)`.
Reads the identity from the session-key file (default:
~/.config/coffer/.session-key). If --auto is passed, prints an informational
message and exits 0 — the identity is always auto-loaded from the file by
every coffer subcommand, so no explicit auto-unlock step is required.
EOF
                return 0
                ;;
            *) die "Unknown argument to unlock: $1" ;;
        esac
    done

    if [[ "$auto" == true ]]; then
        # Since the refactor the identity file IS the persistent store;
        # every coffer subcommand auto-loads it via ensure_unlocked. A
        # dedicated auto-unlock step is no longer meaningful. We log this
        # and return success so legacy LaunchAgents don't flap.
        log "coffer unlock --auto: no-op. Identity is auto-loaded from ${COFFER_SESSION_KEY} by every command."
        return 0
    fi

    # --- Environment shortcut: already unlocked ---
    # If the shell already has SOPS_AGE_KEY set, emit it back so that
    # eval $(coffer unlock) is idempotent and doesn't tamper with the value.
    if [[ -n "${SOPS_AGE_KEY:-}" ]]; then
        log "Already unlocked (SOPS_AGE_KEY set in environment)"
        # Single-quote the value so shell metacharacters in the key (unlikely
        # but possible if the file is ever corrupted) don't get reinterpreted.
        echo "export SOPS_AGE_KEY='${SOPS_AGE_KEY}'"
        return 0
    fi

    # --- Load from session-key file (single source of truth) ---
    local session_key_file="${COFFER_SESSION_KEY}"
    if [[ ! -f "$session_key_file" ]]; then
        coffer_ntfy_urgent "Coffer Locked" "Unlock failed: session-key file missing at ${session_key_file}."
        die "No identity found at ${session_key_file}. Run: coffer init"
    fi
    if [[ ! -r "$session_key_file" ]]; then
        die "Identity file ${session_key_file} is not readable by this user."
    fi

    local secret_key
    secret_key=$(cat "$session_key_file")
    [[ -n "$secret_key" ]] || die "Identity file ${session_key_file} is empty. Run: coffer init"

    # Sanity check: guard against accidentally emitting a non-age blob if
    # someone ever clobbers the file with the wrong content.
    [[ "$secret_key" == AGE-SECRET-KEY-* ]] || die "Identity file does not contain a valid age secret key (expected AGE-SECRET-KEY-* prefix)"

    log "Loaded identity from ${session_key_file}"

    # Output the export command for eval $(coffer unlock).
    # Single-quoted so the caller's shell doesn't reinterpret any characters.
    echo "export SOPS_AGE_KEY='${secret_key}'"
}
