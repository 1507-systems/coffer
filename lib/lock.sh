#!/usr/bin/env bash
# lock.sh -- Emit `unset SOPS_AGE_KEY` for `eval $(coffer lock)`.
#
# Since the April 2026 refactor, the session-key file IS the persistent
# store for coffer's identity — it's the single source of truth. Wiping
# it on `lock` would mean the next `coffer get` requires a full re-init,
# which defeats the purpose of a session-scoped lock. So `coffer lock`
# now ONLY clears the in-memory SOPS_AGE_KEY export from the caller's
# shell; the file stays where it is.
#
# If/when coffer gains a passphrase-encrypted identity file (see SPEC.md
# "Future Work"), `coffer lock` can become a real lock by wiping the
# decrypted session copy while leaving the encrypted at-rest copy in
# place. For now, "lock" is a convention, not a hard security boundary.
#
# Usage: eval $(coffer lock)
set -euo pipefail

cmd_lock() {
    # Only emit the unset — do NOT touch the session-key file. Wiping
    # the file would require the user to `coffer init` again to continue
    # using the vault, which isn't what "lock" should mean. See the
    # header comment for the reasoning and the future passphrase path.
    echo "unset SOPS_AGE_KEY"
    log "Cleared SOPS_AGE_KEY from shell environment."
    log "Note: the identity file at ${COFFER_SESSION_KEY} is unchanged — every"
    log "      subsequent coffer command will re-load it transparently. A"
    log "      passphrase-encrypted identity (future work) will make 'lock'"
    log "      a real at-rest lock; for now it's session-scoped only."
}
