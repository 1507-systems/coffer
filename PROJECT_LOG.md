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

### 2026-04-22 - Multi-machine bootstrap: onboard + finalize-onboard (feat/coffer-onboard-bootstrap)

**Motivation.** The bootstrapping step of adding a new machine to the vault
has broken four times in two weeks:

| Commit | Regression |
|--------|-----------|
| `dce6721` | Verve's pubkey in `.sops.yaml` didn't match its current identity |
| `012eb1b` | Cleanup of a stale Verve pubkey (old identity nobody held) |
| `f51e29d` | `cmd_set` re-encrypted with only the writing machine's key, silently stripping the other recipient |
| `54975bb` | Session-key-file refactor; any machine not yet migrated failed with "No identity found" |

The structural root cause: no tooling existed to transport a new machine's
pubkey to an already-trusted machine without SSH/Tailscale. `coffer init`
printed "run `add-recipient <pubkey>` on the other machine" but provided no
mechanism to make that happen out-of-band.

**Change.** Added two new subcommands in `lib/onboard.sh`:

- **`coffer onboard`** (runs on the new machine): ensures the machine has an
  age identity (runs `coffer init` if missing), then writes the pubkey to
  `vault/.pending-recipient-<machine-name>.pub` — a plaintext file that travels
  via Mutagen and git to all connected machines.

- **`coffer finalize-onboard`** (runs on Wiles or any trusted machine):
  globs `vault/.pending-recipient-*.pub`, validates each key, calls
  `cmd_add_recipient` for each (same code path as `coffer add-recipient`),
  deletes handled files on success, prints a summary + commit reminder.

**Files changed:**
- `lib/onboard.sh` — NEW: `cmd_onboard` + `cmd_finalize_onboard`
- `bin/coffer` — two new case entries + updated help text
- `.gitignore` — `!vault/.pending-recipient-*.pub` allow-list entry
- `SPEC.md` — "Multi-machine Bootstrap" section added
- `PROJECT_LOG.md` — this entry

**Tests.** Added `test_onboard_writes_pending_file`,
`test_onboard_skips_init_if_identity_exists`,
`test_finalize_onboard_no_pending_files`,
`test_onboard_rejects_unknown_args`, and
`test_finalize_onboard_rejects_unknown_args` to `tests/run-tests.sh`.
32/32 tests passing (was 28). Shellcheck clean on all files.

### 2026-04-24 - Vault drift prevention: doctor + auto-sync (feat/doctor-and-auto-sync)

**Root cause of the April 22 SNAFU.** Verve ran `coffer add-recipient <wiles-pubkey>` redundantly (key was already present). The add-recipient code path skipped the `.sops.yaml` write but still ran `sops updatekeys` on all 14 vault files using Verve's local 3-recipient `.sops.yaml`. That re-encrypted ciphertext propagated to Wiles via Mutagen, but Wiles's git-tracked `.sops.yaml` still said 2 recipients. Subsequent `coffer set` calls on Wiles encrypted new entries with only 2 keys, locking Verve out of them.

**Second drift source.** Mutagen syncs file content between machines but does NOT sync git state. A file can be identical in both working trees while each machine's git repo shows wildly different state (staged, untracked, committed-to-different-refs). Auto-pushing on writes means origin/main is always the truth either machine can pull.

**Changes:**

- **`lib/doctor.sh`** (NEW): `cmd_doctor` read-only audit command. Checks: (a) `.sops.yaml` recipient list vs every encrypted vault file's embedded recipient list, (b) this machine's pubkey is in the canonical list, (c) git branch/ahead/behind/dirty-tree state for coffer-managed paths. Exits 0 (clean) or 1 (drift found). Color-coded for TTY, plain ASCII for scripts. Also provides `preflight_recipient_check()` used by write commands.

- **`lib/git-sync.sh`** (NEW): `auto_sync_push <message>` helper. Stages ONLY `config/.sops.yaml` and `vault/` (never the whole working tree), commits if anything changed, pushes when on `main`. Branch != main: commits locally only, logs a warning. `COFFER_AUTO_SYNC=0` disables all git ops (for CI / tests). Never rolls back an on-disk write on git failure.

- **`bin/coffer`**: sourced `git-sync.sh` and `doctor.sh` at startup. Added `doctor` case. Added `preflight_recipient_check` calls before writes in `set` and `edit`. Added `auto_sync_push` calls at end of `set`, `edit`, `import`, `init`, `add-recipient`, `finalize-onboard`. Updated help/usage with `doctor` entry and `COFFER_AUTO_SYNC` env var documentation.

**Auto-sync note:** vault YAML files are gitignored (encrypted bytes travel via Mutagen). `auto_sync_push` is primarily useful for `add-recipient` / `finalize-onboard` which modify `config/.sops.yaml` (git-tracked). The `set`/`edit`/`import` calls log "nothing to sync" for vault file changes, which is correct and expected behavior.

**Tests.** Added 5 new tests covering doctor (clean vault, drifted vault), auto_sync_push (COFFER_AUTO_SYNC=0 skip, non-main branch local-only commit), and preflight blocking on drift. 42/42 tests passing (was 37). Shellcheck clean at warning level on all files.

**Bugs found and fixed during implementation:**
- BSD `paste -s` on macOS requires a file argument (not stdin); replaced with pure-bash join loops.
- `while IFS= read -r` loop over `printf '%s' | tr ',' '\n'` only processed the first token because the last line lacked a trailing newline. Fixed by using `printf '%s\n'` and adding `|| [[ -n "$key" ]]` fallback.
- `git rev-parse --abbrev-ref HEAD` on an empty repo outputs `HEAD` to stdout AND exits 128, causing `HEAD\nunknown` in the branch variable. Fixed with separate assignment: `branch=$(...) || branch="unknown"`.

