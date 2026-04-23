#!/usr/bin/env bash
# onboard.sh -- Multi-machine bootstrap helpers for coffer
#
# PROBLEM THESE COMMANDS SOLVE:
# When adding a new machine (or re-initializing an existing one), the new
# machine's age pubkey must reach an already-trusted machine so that machine
# can call `coffer add-recipient` and re-encrypt the vault. The manual path
# (SSH/paste) has broken four times in two weeks (see PROJECT_LOG.md, commits
# dce6721, 012eb1b, f51e29d, 54975bb). This file provides two subcommands
# that use the Mutagen-synced vault directory itself as the transport medium,
# eliminating the out-of-band dependency.
#
# FLOW:
#   New machine:     coffer onboard
#                    (writes vault/.pending-recipient-<name>.pub, then waits
#                     for Mutagen to sync that file to the trusted machine)
#
#   Trusted machine: coffer finalize-onboard
#                    (reads every .pending-recipient-*.pub, calls
#                     cmd_add_recipient for each, deletes the pending files)
#
# Usage:
#   coffer onboard                  # run on the new / re-init-ed machine
#   coffer finalize-onboard         # run on a machine that can decrypt the vault
set -euo pipefail

# ---------------------------------------------------------------------------
# cmd_onboard
# ---------------------------------------------------------------------------
# Runs on the NEW (or re-initialized) machine.
# Ensures the machine has an age identity (runs init if not), then drops the
# public key into the vault dir as a pending-recipient file so Mutagen carries
# it to the trusted machine.
cmd_onboard() {
    # Parse arguments — no flags currently, but reserve -h for future use.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat >&2 <<'EOF'
Usage: coffer onboard

Prepares this machine to be onboarded to a shared coffer vault.

Steps:
  1. If no identity exists at ${COFFER_SESSION_KEY}, runs `coffer init`
     to generate a fresh age keypair.
  2. Reads the local public key from ${COFFER_CONFIG_DIR}/public-key.
  3. Reads the machine name from ${COFFER_CONFIG_DIR}/machine-name
     (falls back to `hostname -s`).
  4. Writes the public key to vault/.pending-recipient-<machine-name>.pub —
     a plaintext, unencrypted file that travels via Mutagen and git.
  5. Instructs you to wait for Mutagen to sync, then run
     `coffer finalize-onboard` on the trusted machine (Wiles).

The pending file is NOT a secret. Exposing a public key does not compromise
vault security — it only allows someone to add you as a recipient (which
requires `coffer finalize-onboard` on the trusted machine).
EOF
                return 0
                ;;
            *) die "Unknown argument to onboard: $1" ;;
        esac
    done

    local config_dir="${COFFER_CONFIG_DIR}"
    local session_key_file="${COFFER_SESSION_KEY}"

    # --- Step 1: Ensure this machine has an identity ---
    # If the session-key file is missing or empty, we need to init first.
    # We do NOT call cmd_init directly here because init.sh isn't sourced yet
    # and init has interactive prompts. Instead we check the file state and
    # delegate to the bin/coffer dispatcher so the user gets the full init UX.
    if [[ ! -f "$session_key_file" ]] || [[ ! -s "$session_key_file" ]]; then
        # Bug A fix: the old message "running 'coffer init' first..." looked
        # like an instruction to the user to type that command. On Verve
        # (2026-04-22) the user typed "coffer init" at the machine-name prompt
        # and their machine-name was recorded as that string. The new message
        # makes clear that coffer is handling this step automatically, and gives
        # explicit guidance about the upcoming machine-name prompt so the user
        # knows what to do when it appears.
        log "No identity found on this machine. Generating one now."
        log "coffer is running the built-in init flow automatically — do NOT type"
        log "'coffer init'. Just respond to the prompt below."
        log ""
        log "=== Step 1 of 2: generate age identity ==="
        log "You will be prompted for a machine name. Press Enter to accept the default"
        log "(based on hostname), or type a short name like 'verve' or 'macbook'."
        log ""
        # Set COFFER_FROM_ONBOARD so init.sh can suppress its manual-steps output
        # (those steps — add-recipient, import csv — contradict onboard's own flow
        # and would confuse a user who is mid-onboard).
        COFFER_FROM_ONBOARD=1 "${COFFER_ROOT}/bin/coffer" init
        log ""
        log "=== Step 2 of 2: register this machine for vault access ==="
        log ""
    fi

    # --- Step 2: Read the local public key ---
    local pubkey_file="${config_dir}/public-key"
    if [[ ! -f "$pubkey_file" ]] || [[ ! -s "$pubkey_file" ]]; then
        die "Public key file not found at ${pubkey_file}. Run: coffer init"
    fi

    local pubkey
    pubkey=$(< "$pubkey_file")
    pubkey="${pubkey%%[[:space:]]*}"  # strip any trailing whitespace/newline

    # Validate the key looks like an age pubkey (same check as add-recipient.sh).
    if [[ ! "$pubkey" =~ ^age1[a-z0-9]{58}$ ]]; then
        die "Public key at ${pubkey_file} does not look like a valid age public key (expected age1<58 chars>). Try re-running 'coffer init'."
    fi

    # --- Step 3: Determine machine name ---
    local machine_name_file="${config_dir}/machine-name"
    local machine_name=""
    if [[ -f "$machine_name_file" ]] && [[ -s "$machine_name_file" ]]; then
        machine_name=$(< "$machine_name_file")
        # Bug B fix: the previous pattern `${var%%[[:space:]]*}` stripped
        # everything from the FIRST whitespace character onward, not just
        # trailing whitespace. A machine name of "my laptop" became "my";
        # worse, "coffer init" (typed by a confused user during onboard) became
        # "coffer". Intent was only to strip leading and trailing whitespace
        # (newlines, spaces) that accumulate from echo/read writes.
        # The two-step trim below strips only boundary whitespace and leaves
        # internal spaces intact so the sanitization step can convert them to
        # hyphens (e.g., "my laptop" → "my-laptop").
        # Strip leading whitespace
        machine_name="${machine_name#"${machine_name%%[![:space:]]*}"}"
        # Strip trailing whitespace
        machine_name="${machine_name%"${machine_name##*[![:space:]]}"}"
    fi
    if [[ -z "$machine_name" ]]; then
        machine_name=$(hostname -s 2>/dev/null || echo "unknown")
        log "machine-name file not found; falling back to hostname: ${machine_name}"
    fi

    # Sanitize machine name to safe filename characters (alphanumeric, hyphen,
    # underscore). This prevents path traversal if a maliciously-crafted
    # machine-name file contains slashes, dots, or shell metacharacters.
    # Example: "../../evil" → "--evil" (safe, won't escape vault/).
    local safe_machine_name
    safe_machine_name=$(printf '%s' "$machine_name" | tr -cs 'a-zA-Z0-9_-' '-')
    if [[ "$safe_machine_name" != "$machine_name" ]]; then
        log "Machine name sanitized: '${machine_name}' → '${safe_machine_name}'"
    fi
    machine_name="$safe_machine_name"

    # --- Step 4: Write the pending-recipient file to the vault directory ---
    # This file is NOT encrypted — a pubkey is not a secret. It lives in
    # vault/ so Mutagen syncs it to all connected machines. It must also be
    # tracked by git (see .gitignore allow-list entry) so if Mutagen isn't
    # running the file still reaches the trusted machine via git push/pull.
    local vault_dir="${COFFER_VAULT}"
    [[ -d "$vault_dir" ]] || die "Vault directory not found at ${vault_dir}. Run: coffer init"

    local pending_file="${vault_dir}/.pending-recipient-${machine_name}.pub"
    printf '%s\n' "$pubkey" > "$pending_file"

    log "Pending-recipient file written: ${pending_file}"
    log ""

    # --- Step 5: Instructions for the operator ---
    cat >&2 <<EOF
coffer: Wrote pending recipient file for ${machine_name}:
coffer:   ${pending_file}

coffer: Next steps:
coffer:   1. Wait for Mutagen to sync the vault (or git push/pull if Mutagen is not running).
coffer:   2. On the already-trusted machine (Wiles), run:
coffer:        coffer finalize-onboard
coffer:   3. After finalize-onboard completes, Mutagen will sync the re-encrypted vault back.
coffer:   4. Verify on this machine: coffer list
EOF
    return 0
}

# ---------------------------------------------------------------------------
# cmd_finalize_onboard
# ---------------------------------------------------------------------------
# Runs on a machine that ALREADY has a valid identity and can decrypt the vault.
# Scans the vault dir for .pending-recipient-*.pub files, calls cmd_add_recipient
# for each, and deletes the handled files.
cmd_finalize_onboard() {
    # Parse arguments — no flags currently.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat >&2 <<'EOF'
Usage: coffer finalize-onboard

Completes onboarding for any machines that have run `coffer onboard`.

Steps:
  1. Scans vault/.pending-recipient-*.pub for files left by `coffer onboard`.
  2. For each: validates the pubkey, calls `coffer add-recipient` logic, then
     deletes the pending file.
  3. Prints a summary and reminds you to commit + push so Mutagen can sync the
     re-encrypted vault back to the new machine.

Run on the already-trusted machine (Wiles) after Mutagen has synced the
pending-recipient file(s) from the new machine.
EOF
                return 0
                ;;
            *) die "Unknown argument to finalize-onboard: $1" ;;
        esac
    done

    require_cmd sops
    ensure_unlocked

    local vault_dir="${COFFER_VAULT}"
    [[ -d "$vault_dir" ]] || die "Vault directory not found at ${vault_dir}. Run: coffer init"

    # --- Step 1: Find pending-recipient files ---
    # Use find so the glob is evaluated at runtime and an empty match doesn't
    # expand to the literal pattern (avoids nullglob requirement in bash).
    local pending_files=()
    while IFS= read -r f; do
        pending_files+=("$f")
    done < <(find "$vault_dir" -maxdepth 1 -name '.pending-recipient-*.pub' | sort)

    if [[ ${#pending_files[@]} -eq 0 ]]; then
        log "No pending recipients found in ${vault_dir}."
        log "Nothing to do. Run 'coffer onboard' on the new machine first."
        return 0
    fi

    log "Found ${#pending_files[@]} pending recipient file(s):"
    for f in "${pending_files[@]}"; do
        log "  $(basename "$f")"
    done
    log ""

    # --- Step 2: Process each pending file ---
    # We source add-recipient.sh here (once) so cmd_add_recipient is available
    # for the loop without re-sourcing it per iteration.
    # shellcheck source=./add-recipient.sh
    source "${COFFER_ROOT}/lib/add-recipient.sh"

    local added=0
    local failed=0

    for pending_file in "${pending_files[@]}"; do
        local filename
        filename=$(basename "$pending_file")

        # Extract machine name from filename (.pending-recipient-<name>.pub)
        local machine_name="${filename#.pending-recipient-}"
        machine_name="${machine_name%.pub}"

        log "Processing: ${filename} (machine: ${machine_name})"

        # Read pubkey — strip whitespace (trailing newlines, spaces)
        local pubkey
        pubkey=$(< "$pending_file")
        pubkey="${pubkey%%[[:space:]]*}"

        # Validate the key format before calling cmd_add_recipient.
        # This mirrors the check in add-recipient.sh; we do it here too so
        # we can skip a malformed file without dying the whole loop.
        if [[ ! "$pubkey" =~ ^age1[a-z0-9]{58}$ ]]; then
            warn "Skipping ${filename}: content does not look like a valid age public key."
            warn "  Got: '${pubkey:0:20}...' (expected: age1<58 lowercase alphanumeric chars>)"
            failed=$((failed + 1))
            # Leave the file in place so the operator can inspect it.
            continue
        fi

        # Call the shared add-recipient function. If it fails, log + continue
        # (leave the pending file so the operator knows which one failed).
        if cmd_add_recipient "$pubkey"; then
            log "Added recipient for ${machine_name}: ${pubkey}"

            # Delete the pending file only on success.
            # Trash-move isn't needed here: the pending file contains only a
            # public key (not secret), and it's tracked in git so the history
            # record lives in git. A plain rm is correct.
            rm "$pending_file"
            log "Deleted: ${pending_file}"
            added=$((added + 1))
        else
            warn "cmd_add_recipient failed for ${machine_name} (${pubkey})."
            warn "Pending file left in place: ${pending_file}"
            failed=$((failed + 1))
        fi

        log ""
    done

    # --- Step 3: Summary ---
    echo "" >&2
    log "=== finalize-onboard complete ==="
    log "  Added: ${added} recipient(s)"
    log "  Failed: ${failed}"
    echo "" >&2

    if [[ $added -gt 0 ]]; then
        cat >&2 <<'EOF'
coffer: IMPORTANT: Commit and push the coffer repo so the re-encrypted vault
coffer: travels back to the new machine via Mutagen (or git pull on that machine):
coffer:
coffer:   cd ~/dev/coffer
coffer:   git add config/.sops.yaml vault/
coffer:   git commit -m "chore: add recipient via coffer finalize-onboard"
coffer:   git push
coffer:
coffer: After Mutagen syncs (or the new machine runs git pull), verify on the
coffer: new machine:
coffer:   coffer list
EOF
    fi

    if [[ $failed -gt 0 ]]; then
        die "${failed} recipient(s) failed to add. Check warnings above."
    fi

    return 0
}
