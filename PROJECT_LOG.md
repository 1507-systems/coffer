<!-- summary: Offline encrypted secrets vault CLI using SOPS + age for developer credentials on macOS. -->
# Coffer - Project Log

## Overview
Offline encrypted secrets vault for developer credentials on macOS, using SOPS + age.

---

### 2026-04-07 - Project initialized
- Created SPEC.md with full architecture, CLI design, sync strategy, and keychain migration plan
- Project directory created in iCloud dev folder

### 2026-04-08 - Initial implementation (feat/initial-implementation)
- Built complete CLI tool: `bin/coffer` dispatcher + 8 lib/ modules
  - `common.sh`: die() with ntfy, warn(), log(), require_cmd(), parse_path(), ensure_unlocked()
  - `init.sh`: age keypair generation, passphrase encryption, optional keychain storage
  - `get.sh`: decrypt single value via sops --extract, supports --clip and --newline
  - `set.sh`: decrypt-update-reencrypt flow via yq, supports --stdin and interactive prompt
  - `list.sh`: reads plaintext YAML keys (no decryption needed), tree format output
  - `edit.sh`: delegates to sops native decrypt-edit-reencrypt
  - `import.sh`: CSV parser with keychain-mapping.yaml lookup, summary output
  - `unlock.sh`: passphrase prompt or --auto (keychain), session key file for headless
  - `lock.sh`: zero-overwrite session key file, unset env var
- Config files: categories.yaml (6 categories), keychain-mapping.yaml (30 service mappings)
- ShellCheck CI workflow (.github/workflows/shellcheck.yml)
- Test suite: 16 tests covering helpers, list, get errors, and entrypoint dispatch
- All scripts pass shellcheck with zero warnings/errors
- GitHub repo created: 1507-systems/coffer (public)

### 2026-04-13 - Full Audit

**Phase 1: Documentation**
- PROJECT_LOG.md and SPEC.md accurate; added `<!-- summary -->` marker

**Phase 2: Functionality**
- All 16 tests pass
- ShellCheck: zero warnings/errors on all scripts
- No dead code, no stale TODOs

**Phase 3: Security**
- macOS Keychain usage in `init.sh`, `unlock.sh`, `common.sh` is by design: coffer is the
  credential vault itself and needs bootstrap storage for the age secret key. Keychain stores
  only the root age identity — all other secrets are in the SOPS-encrypted vault.
- `set.sh` uses `--stdin` for piped input; `import.sh` passes values via shell function
  parameters (not subprocess CLI args), so no ps exposure risk
- Session key file (`~/.config/coffer/.session-key`) has chmod 600 and is zeroed on lock
- No hardcoded secrets in source
- `die()` sends ntfy notifications on all failures

**Result**: Clean on first pass. No code changes required.

### 2026-04-19 - Single-source identity refactor (refactor/single-source-identity)

**Problem.** `require_identity()` tested macOS Keychain presence while
`ensure_unlocked()` had a Keychain fallback *plus* a session-key file
fallback. The two functions disagreed: contexts where the Keychain was
unavailable (SSH-spawned shells, non-GUI processes) would die at the
identity check even when `.session-key` was present and valid. This
produced repeat "No identity found" failures in cron jobs and
SSH-driven backup scripts, and a general "false alert" pattern the user
surfaced in session transcripts.

**Change.** Collapsed the dual identity model to a single source of
truth: the session-key file at `${COFFER_SESSION_KEY}` (default
`~/.config/coffer/.session-key`, mode 600).

- `lib/common.sh`: `require_identity()` checks file presence / readability /
  non-emptiness only. `ensure_unlocked()` is exactly two paths — env var,
  then file. Both die with actionable errors pointing at `coffer init`.
- `lib/init.sh`: writes the age secret key directly to the session-key
  file (mode 600, under a tightened umask). No Keychain write. Refuses
  to overwrite an existing identity unless `--force` is passed.
- `lib/unlock.sh`: reads the session-key file and emits
  `export SOPS_AGE_KEY=...`. `--auto` is retained as a documented no-op
  for LaunchAgent backward compatibility.
- `lib/lock.sh`: emits `unset SOPS_AGE_KEY` only — does NOT delete the
  session-key file, because the file is the persistent identity store.
- No library/bin code calls the macOS `security` helper anymore; a
  structural test (`test_no_keychain_calls_in_library`) enforces that.
- `SPEC.md`: added "Identity and Unlock Model" section (threat-model
  equivalence, single-source rationale, future passphrase-encrypted
  identity). Removed obsolete "Auto-Unlock at Boot", "Remote Unlock
  from Verve", "wiles-unlock", and "Keychain Safety Rules" sections —
  their contents were never implemented and their premise (Keychain
  holds the master passphrase) is gone.

**Breaking change.** A machine whose identity lived ONLY in the Keychain
(no `.session-key` file) will now fail with "No identity found". Recovery
on such a machine:

1. Retrieve the old age secret key from Keychain:
   `security find-generic-password -s "Coffer" -a "coffer-secret-key" -w`
2. Write it to the session-key file:
   `umask 077; printf '%s\n' "<key>" > ~/.config/coffer/.session-key; chmod 600 ~/.config/coffer/.session-key`
3. Optionally delete the Keychain entry:
   `security delete-generic-password -s "Coffer" -a "coffer-secret-key"`

If the old Keychain entry is lost, run `coffer init --force` on the
affected machine and re-register its new pubkey as a SOPS recipient
on the other machine (`coffer add-recipient`).

**Tests.** 28/28 passing (added 10 new tests covering the file-only
identity model: happy path, missing file, empty file, env-var
precedence, SSH/headless simulation, structural Keychain-free guard,
`coffer unlock` and `coffer lock` smoke). Shellcheck clean on `bin/`
and `lib/`.

