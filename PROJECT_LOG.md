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
