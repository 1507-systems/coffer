# Coffer - Specification

**Offline Encrypted Secrets Vault for macOS Developer Credentials**

Version: 1.0.0-draft
Created: 2026-04-07
Last significant revision: 2026-04-19 (single-source identity refactor)
Status: Design

---

## Table of Contents

1. [Overview](#overview)
2. [Goals and Non-Goals](#goals-and-non-goals)
3. [Architecture](#architecture)
4. [Encryption Design](#encryption-design)
5. [Directory Structure](#directory-structure)
6. [Storage Format](#storage-format)
7. [CLI Interface](#cli-interface)
8. [Data Flow](#data-flow)
9. [Sync Strategy (Mutagen)](#sync-strategy-mutagen)
10. [Error Handling](#error-handling)
11. [Security Model](#security-model)
12. [Identity and Unlock Model](#identity-and-unlock-model)
13. [Keychain Migration (historical)](#keychain-migration-historical)
14. [Category Mapping](#category-mapping)
15. [Import CSV Format](#import-csv-format)
16. [Dependencies](#dependencies)
17. [Future Work](#future-work)

---

## Overview

Coffer is an offline, encrypted secrets vault that replaces macOS Keychain as the primary store for API tokens, passwords, and developer credentials. It uses **SOPS** for structured encryption and **age** for the underlying cryptography, producing human-readable YAML files where keys are visible but values are encrypted.

Coffer's own age identity (the private key it uses to decrypt vault
files) is stored in a single local file at `~/.config/coffer/.session-key`
(mode 600) — no Keychain dependency. See [Identity and Unlock Model](#identity-and-unlock-model)
for the design rationale.

The vault is designed for a 2-machine setup:
- **Wiles** (Mac Mini 2018, 64GB RAM) -- primary dev machine
- **Verve** (MacBook Air) -- mobile machine

Encrypted files sync between machines via **Mutagen** (not iCloud), ensuring the vault works fully offline on both machines.

---

## Goals and Non-Goals

### Goals
- Replace macOS Keychain for all developer credentials used by Claude Code and automation scripts
- Encrypted at rest with strong, modern cryptography (XChaCha20-Poly1305 via age)
- Human-readable structure (SOPS preserves YAML keys in cleartext, encrypts only values)
- Works completely offline -- no cloud APIs, no network calls for encrypt/decrypt
- Simple CLI that outputs secrets to stdout for piping into other commands
- Two-machine sync with clear conflict resolution
- Easy to audit (shell scripts, standard tools, no compiled binaries)
- Fail loudly on every error

### Non-Goals
- GUI application
- Browser extension or autofill
- Sharing secrets with other users (single-user vault)
- Real-time sync (eventual consistency via Mutagen is acceptable)
- Mobile device support
- Secret versioning or history (git handles this at the repo level)

---

## Architecture

```
                    ┌─────────────────────────────────────────┐
                    │              coffer CLI                 │
                    │         (bash, bin/coffer)              │
                    └──────┬──────────────────┬───────────────┘
                           │                  │
                    ┌──────▼──────┐    ┌──────▼──────┐
                    │   lib/*.sh  │    │  age identity│
                    │  (commands) │    │  (~/.config/ │
                    │             │    │   coffer/)  │
                    └──────┬──────┘    └──────┬───────┘
                           │                  │
                    ┌──────▼──────────────────▼───────────────┐
                    │              SOPS                        │
                    │  (encrypts/decrypts using age backend)  │
                    └──────┬──────────────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │  vault/*.yaml│
                    │ (encrypted) │
                    └──────┬──────┘
                           │
                    ┌──────▼──────────────────────────────────┐
                    │           Mutagen File Sync              │
                    │     Wiles <──────────────> Verve         │
                    └─────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Role |
|-----------|------|
| `bin/coffer` | CLI entrypoint, argument parsing, dispatches to lib/ functions |
| `lib/*.sh` | Individual command implementations (get, set, list, edit, import, init) |
| `config/.sops.yaml` | SOPS configuration defining age recipients for each path pattern |
| `config/categories.yaml` | Category definitions (names, descriptions, default keys) |
| `vault/*.yaml` | SOPS-encrypted YAML files (one per category) |
| `~/.config/coffer/.session-key` | Machine-local age private key (plaintext, mode 600, never synced, never committed). Single source of truth for coffer's identity; see [Identity and Unlock Model](#identity-and-unlock-model). |
| Mutagen | Syncs the coffer directory between Wiles and Verve |

---

## Encryption Design

### Algorithm
- **age** with XChaCha20-Poly1305 (AEAD)
- Key derivation: **scrypt KDF** with passphrase-based encryption for the identity file itself
- Each machine generates its own age keypair during `coffer init`

### Multi-Recipient Encryption
Every SOPS-encrypted file is encrypted to **all authorized age public keys**. This means any machine with a registered keypair can decrypt any file in the vault without needing the other machine's private key.

```
# .sops.yaml
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1wiles_public_key_here,
      age1verve_public_key_here
```

### Identity-at-Rest Protection (current implementation)
The age identity (secret key) is stored **in cleartext** at
`~/.config/coffer/.session-key` with mode 600, owned by the invoking user.
At-rest protection comes from three layers — FileVault (full-disk
encryption while the Mac is locked/powered-off), UNIX permissions
(other local users cannot read the file), and user isolation. This is
equivalent to the effective security of a default-ACL macOS Keychain
entry on an unlocked Mac: in both cases, any process running as the
user can read the key. See [Identity and Unlock Model](#identity-and-unlock-model)
for the full threat-model discussion and the rationale for choosing
this over a dual file+Keychain design.

A passphrase-encrypted identity file (age scrypt KDF wrapping the
session key) is listed in [Future Work](#future-work) as the next
hardening step if/when a stronger at-rest posture is required.

### SOPS Integration
SOPS handles the structured encryption layer:
- Encrypts individual YAML values while leaving keys in plaintext
- Manages the MAC (message authentication code) for tamper detection
- Handles multi-recipient encryption natively via its age backend
- Stores encryption metadata in the YAML file itself (under `sops:` key)

---

## Directory Structure

```
coffer/
├── SPEC.md                          # This document
├── PROJECT_LOG.md                   # Change history and decisions
├── bin/
│   └── coffer                      # Main CLI entrypoint (bash)
├── lib/
│   ├── init.sh                      # First-time setup
│   ├── get.sh                       # Retrieve a secret value
│   ├── set.sh                       # Store or update a secret
│   ├── list.sh                      # List categories and keys
│   ├── edit.sh                      # Interactive edit (decrypt -> $EDITOR -> re-encrypt)
│   ├── import.sh                    # Import from keychain CSV dump
│   ├── add-recipient.sh             # Register another machine's public key
│   └── rekey.sh                     # Re-encrypt all vault files for current recipients
├── config/
│   ├── .sops.yaml                   # SOPS creation rules (age recipients)
│   ├── categories.yaml              # Category metadata (descriptions, expected keys)
│   └── keychain-mapping.yaml        # Maps keychain service names to coffer paths
├── vault/                           # Encrypted YAML files (synced via Mutagen)
│   ├── cloudflare.yaml
│   ├── github.yaml
│   ├── home-automation.yaml
│   ├── synology.yaml
│   ├── communications.yaml
│   └── misc.yaml
├── .gitignore
├── .shellcheckrc
└── .github/
    └── workflows/
        └── shellcheck.yml
```

### Files NOT in the repo / NOT synced
- `~/.config/coffer/.session-key` -- age private key (cleartext, mode 600, machine-local). Single source of truth for coffer's identity; see [Identity and Unlock Model](#identity-and-unlock-model).
- `~/.config/coffer/public-key` -- age public key for this machine (used when registering as a recipient on the other machine). Not secret.
- `~/.config/coffer/machine-name` -- plaintext file containing "wiles" or "verve", used for ntfy alert tagging.

---

## Storage Format

Each vault file is a standard YAML file encrypted by SOPS. Before encryption, a file looks like:

```yaml
# vault/cloudflare.yaml (decrypted view)
dns-token: "the-actual-token-value"
pages-token: "another-token-value"
zone-mgmt-1507systems: "zone-token-here"
zone-mgmt-shashinka: "zone-token-here"
zone-mgmt-hellgaskitchen: "zone-token-here"
```

After SOPS encryption, the same file looks like:

```yaml
# vault/cloudflare.yaml (encrypted, on disk)
dns-token: ENC[AES256_GCM,data:abc123...,iv:...,tag:...,type:str]
pages-token: ENC[AES256_GCM,data:def456...,iv:...,tag:...,type:str]
zone-mgmt-1507systems: ENC[AES256_GCM,data:ghi789...,iv:...,tag:...,type:str]
zone-mgmt-shashinka: ENC[AES256_GCM,data:jkl012...,iv:...,tag:...,type:str]
zone-mgmt-hellgaskitchen: ENC[AES256_GCM,data:mno345...,iv:...,tag:...,type:str]
sops:
    kms: []
    gcp_kms: []
    azure_kv: []
    hc_vault: []
    age:
        - recipient: age1wiles...
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            ...
            -----END AGE ENCRYPTED FILE-----
        - recipient: age1verve...
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            ...
            -----END AGE ENCRYPTED FILE-----
    lastmodified: "2026-04-07T00:00:00Z"
    mac: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
    version: 3.9.4
```

Key design properties:
- **Keys are plaintext** -- you can `grep` for a secret name without decrypting
- **Values are individually encrypted** -- SOPS encrypts each value separately
- **MAC protects integrity** -- tampering with any key or value is detected
- **Multiple recipients** -- each recipient block allows that machine to decrypt

---

## CLI Interface

### Entrypoint: `bin/coffer`

```bash
#!/usr/bin/env bash
set -euo pipefail
```

The CLI uses a subcommand pattern. All commands source shared configuration (coffer root directory, identity path, SOPS config path).

### Commands

#### `coffer get <category/key>`
Decrypt and print a single secret value to stdout.

```bash
coffer get cloudflare/dns-token
# Output: the-actual-token-value (no trailing newline by default)

# Usage in scripts:
export CF_TOKEN=$(coffer get cloudflare/dns-token)
```

**Behavior:**
1. Parse `category/key` into file path (`vault/<category>.yaml`) and YAML key
2. Set `SOPS_AGE_KEY_FILE` to the identity path
3. Run `sops decrypt --extract '["<key>"]' vault/<category>.yaml`
4. Print value to stdout (no newline unless `--newline` flag)
5. Exit 0 on success, non-zero on any error

**Flags:**
- `--newline` / `-n` -- append a newline after the value (useful for interactive use)
- `--clip` / `-c` -- copy to clipboard instead of stdout (via `pbcopy`), auto-clears after 30 seconds

#### `coffer set <category/key> [value]`
Store or update a secret.

```bash
coffer set cloudflare/dns-token              # prompts securely for value
coffer set cloudflare/dns-token "new-value"  # sets directly (avoid in shell history)
echo "new-value" | coffer set cloudflare/dns-token --stdin  # pipe in
```

**Behavior:**
1. If value not provided as argument and `--stdin` not set, prompt with `read -s`
2. Decrypt the full category file to memory (via process substitution)
3. Update/insert the key-value pair using `yq`
4. Re-encrypt with SOPS and write back to `vault/<category>.yaml`
5. If the category file does not exist, create it

**Flags:**
- `--stdin` -- read value from stdin instead of argument or prompt

#### `coffer list [category]`
List available secrets.

```bash
coffer list                # all categories and their keys
coffer list cloudflare     # keys within cloudflare category
```

**Behavior (no args):**
1. List all `.yaml` files in `vault/`
2. For each file, extract key names (these are plaintext in SOPS files, so no decryption needed)
3. Print in tree format:
   ```
   cloudflare/
     dns-token
     pages-token
     zone-mgmt-1507systems
     zone-mgmt-shashinka
     zone-mgmt-hellgaskitchen
   github/
     ...
   ```

**Behavior (with category):**
1. Extract and list keys from `vault/<category>.yaml`
2. No decryption needed (keys are plaintext)

**Implementation note:** Since SOPS leaves keys in plaintext, `coffer list` can work by parsing the YAML structure and filtering out the `sops:` metadata block. Use `yq` to extract top-level keys excluding `sops`.

#### `coffer edit <category>`
Open a category file for interactive editing.

```bash
coffer edit cloudflare
```

**Behavior:**
1. Verify `$EDITOR` is set (fail if not)
2. Use `sops vault/<category>.yaml` (SOPS handles decrypt-edit-reencrypt natively)
3. SOPS will decrypt to a temp file, open `$EDITOR`, re-encrypt on save, and securely delete the temp file
4. SOPS's built-in flow handles the security here

**Note:** This is the one case where a decrypted temp file briefly exists (managed by SOPS, not by us). SOPS uses `os.CreateTemp` with restrictive permissions and deletes immediately after the editor closes.

#### `coffer import <csv-file>`
Import secrets from a keychain CSV dump.

```bash
coffer import keychain-backup.csv
```

**Behavior:**
1. Read the CSV (columns: `service,account,password`)
2. Load the mapping file (`config/keychain-mapping.yaml`) to translate service names to coffer paths
3. For each row:
   a. Look up the service name in the mapping
   b. If mapped, call the `set` function with the mapped `category/key` and the password value
   c. If not mapped, print a warning and skip
4. Print a summary (imported count, skipped count, errors)

#### `coffer init [--force]`
First-time setup on a new machine.

```bash
coffer init            # fresh setup
coffer init --force    # overwrite an existing identity (DESTRUCTIVE)
```

**Behavior:**
1. Check for an existing identity at `${COFFER_SESSION_KEY}` (default
   `~/.config/coffer/.session-key`). If present, abort unless `--force`
   is passed. Overwriting a working identity locks you out of any vault
   files that were encrypted only to that key.
2. Prompt for machine name (suggest based on hostname) and save it to
   `~/.config/coffer/machine-name`.
3. Generate a new age keypair via `age-keygen`.
4. Write the secret key to `${COFFER_SESSION_KEY}` with mode 600
   (umask is tightened before the write so the file is never briefly
   world-readable).
5. Write the public key to `~/.config/coffer/public-key` (not secret).
6. If `config/.sops.yaml` does not exist, create it with this public key
   as the sole recipient (first-machine setup). Otherwise leave it alone
   and instruct the user to run `coffer add-recipient <pubkey>` on the
   other machine so both machines can decrypt the shared vault.
7. Create `vault/` and placeholder category files if they don't exist.

**No Keychain interaction.** The `.session-key` file IS the persistent
identity store — see [Identity and Unlock Model](#identity-and-unlock-model)
for the rationale.

#### `coffer add-recipient <age-public-key>`
Register another machine's public key.

```bash
coffer add-recipient age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

**Behavior:**
1. Validate the key format (must start with `age1`)
2. Append the key to the recipient list in `config/.sops.yaml`
3. Run `coffer rekey` to re-encrypt all vault files for the new recipient set

#### `coffer rekey`
Re-encrypt all vault files for the current set of recipients.

```bash
coffer rekey
```

**Behavior:**
1. Read current recipients from `config/.sops.yaml`
2. For each file in `vault/*.yaml`:
   a. Run `sops updatekeys vault/<file>.yaml` (SOPS handles rekey natively)
3. Print summary of rekeyed files

---

## Data Flow

### Reading a secret (`coffer get`)

```
User runs: coffer get cloudflare/dns-token
    │
    ▼
Parse args: category = "cloudflare", key = "dns-token"
    │
    ▼
Verify vault/cloudflare.yaml exists (fail loudly if not)
    │
    ▼
Set SOPS_AGE_KEY_FILE=~/.config/coffer/identity.txt
    │
    ▼
age prompts for passphrase (scrypt decrypts identity)
    │
    ▼
sops decrypt --extract '["dns-token"]' vault/cloudflare.yaml
    │
    ▼
SOPS decrypts value using age private key
    │
    ▼
Value printed to stdout (never touches disk)
```

### Writing a secret (`coffer set`)

```
User runs: coffer set cloudflare/dns-token
    │
    ▼
Parse args, prompt for value with read -s
    │
    ▼
Decrypt full file to variable: content=$(sops -d vault/cloudflare.yaml)
    │
    ▼
Update YAML in memory: updated=$(echo "$content" | yq '.dns-token = "new-value"')
    │
    ▼
Re-encrypt and write: echo "$updated" | sops encrypt --input-type yaml --output-type yaml /dev/stdin > vault/cloudflare.yaml
    │
    ▼
Done (decrypted content only existed in shell variables / pipes)
```

### Identity loading at runtime

Every coffer subcommand auto-loads the identity via `ensure_unlocked()`
in `lib/common.sh`. The logic is intentionally minimal — exactly two
paths in a strict order:

1. **`SOPS_AGE_KEY` already set in the environment.** Trust it, return.
   This supports `eval $(coffer unlock)` having been run in the parent
   shell and also alternative delivery mechanisms (e.g., a CI job runner
   that injects the key from its own secret manager). Coffer does not
   rewrite a pre-set value.
2. **Read `${COFFER_SESSION_KEY}` from disk** (default
   `~/.config/coffer/.session-key`). Load the contents, export as
   `SOPS_AGE_KEY`, return.

If neither is available, coffer dies with an actionable error:

    No identity found at ~/.config/coffer/.session-key. Run: coffer init

**There is no Keychain fallback.** The previous implementation had one,
but it produced inconsistent behavior between `require_identity` (which
demanded Keychain access) and `ensure_unlocked` (which had a file
fallback), causing SSH-spawned shells to fail at the identity check
even when the session-key file was readable and valid. See
[Identity and Unlock Model](#identity-and-unlock-model) for the full
design rationale.

**`eval $(coffer unlock)`** is a convenience that reads the file and
emits the corresponding `export SOPS_AGE_KEY=...` line, so the user's
interactive shell retains the key for subsequent ad-hoc coffer
invocations without re-reading the file each time. It is not required
for coffer to work — every subcommand can load the file directly.

**`coffer lock`** emits `unset SOPS_AGE_KEY` for the caller's shell and
does NOT delete the session-key file. The file is the persistent store;
wiping it would force a full `coffer init` on every "lock". A real
lock-at-rest capability (passphrase-encrypted identity file) is listed
in [Future Work](#future-work).

**Headless machines (Wiles):** The session-key file covers this use
case natively — no LaunchAgent, no boot-time unlock step, no Keychain
dance. The LaunchAgent recipe that used to live in this section has
been removed; `coffer unlock --auto` is retained as a documented no-op
so any legacy LaunchAgent still configured on a machine continues to
exit 0 without side effects.

**Laptops (Verve):** Same model. If the user wants their credentials
to clear on sleep or shutdown, they can put a `coffer lock` in a logout
hook or simply not worry about it (FileVault re-locks the disk on
shutdown).

---

## Sync Strategy (Mutagen)

### Why Mutagen (not iCloud)
- iCloud has no conflict resolution strategy visible to the user
- iCloud syncs are unpredictable in timing and order
- Mutagen provides explicit sync modes with configurable conflict resolution
- Mutagen supports SSH transport (no cloud intermediary)

### Mutagen Configuration

```yaml
# ~/.mutagen/mutagen.yml (relevant section)
sync:
  coffer:
    alpha: "/Users/bryce/dev/coffer/vault"
    beta: "wiles:/Users/rogue/dev/coffer/vault"
    mode: "two-way-resolved"
    resolve:
      strategy: "alpha-wins"
    ignore:
      paths:
        - ".DS_Store"
```

**Wait -- since both machines use the same iCloud path, Mutagen syncs the `vault/` directory specifically (not the whole coffer directory).** The rest of the project (bin, lib, config) syncs via iCloud or git. Only the vault files need the tighter sync control.

Actually, a cleaner approach: the coffer project itself lives in git. The vault directory is gitignored and synced exclusively via Mutagen. This separates code (git) from secrets (Mutagen).

### Conflict Resolution Strategy

**The problem:** Mutagen has no file locking. If both machines edit the same vault file before a sync completes, a conflict occurs.

**The strategy: "alpha-wins" with operational discipline**

1. **Mutagen mode**: `two-way-resolved` with `alpha-wins` (Wiles is alpha since it is the primary dev machine)
2. **Operational rule**: Only edit secrets on one machine at a time. This is practical because:
   - Secrets change rarely (new token, rotation)
   - Only one person uses both machines
   - The CLI can warn if the vault file's mtime is very recent (< 60 seconds), suggesting a sync may be in progress
3. **Pre-edit sync check**: Before any write operation, `coffer` runs `mutagen sync list` to check sync status. If a sync is in progress or paused, it warns the user and asks for confirmation.
4. **Post-edit sync flush**: After any write operation, `coffer` runs `mutagen sync flush coffer` to trigger an immediate sync.
5. **Conflict recovery**: If a conflict does occur (alpha-wins discards beta changes):
   - Mutagen logs the conflict
   - The discarded version can be recovered from Mutagen's staging directory
   - `coffer` can provide a `coffer sync-status` command that surfaces Mutagen conflict state

### What gets synced where

| Component | Sync Method | Reason |
|-----------|-------------|--------|
| `bin/`, `lib/`, `config/`, `SPEC.md`, etc. | Git (private repo) | Code changes, versioned |
| `vault/*.yaml` | Mutagen (two-way-resolved) | Encrypted secrets, not in git |
| `~/.config/coffer/identity.txt` | NEVER synced | Machine-local private key |
| `~/.config/coffer/machine-name` | NEVER synced | Machine identifier |

---

## Error Handling

### Philosophy
Every error is fatal and loud. No silent fallbacks. The user must know immediately when something fails.

### Error Conditions

| Condition | Behavior |
|-----------|----------|
| Missing `sops` binary | Exit 1, print: "sops not found. Install: brew install sops" |
| Missing `age` binary | Exit 1, print: "age not found. Install: brew install age" |
| Missing `yq` binary | Exit 1, print: "yq not found. Install: brew install yq" |
| Identity file missing | Exit 1, print: "No identity found at ~/.config/coffer/.session-key. Run: coffer init" |
| Identity file unreadable (perms/ownership wrong) | Exit 1, print: "Identity file ... is not readable by this user." |
| Identity file empty (corruption) | Exit 1, print: "Identity file ... is empty. Run: coffer init (or restore from backup)." |
| Category file not found | Exit 1, print: "Category '<name>' not found. Available: ..." |
| Key not found in category | Exit 1, print: "Key '<key>' not found in '<category>'. Available keys: ..." |
| SOPS MAC verification failure | Exit 1, print: "Integrity check failed for <file>. File may be tampered or corrupted." |
| Mutagen sync in progress (on write) | Warn, prompt for confirmation, proceed if user confirms |
| SOPS decrypt failure (general) | Exit 1, propagate SOPS error message verbatim |

### Urgent Notifications on Failure

**All failures must push to ntfy as urgent.** Any coffer operation that fails (decrypt error, file not found, SOPS error, sync conflict) must send an ntfy notification with priority "urgent" before exiting. This ensures the user is alerted immediately on any device (phone, watch, desktop).

```bash
# ntfy notification pattern for all errors:
curl -s -H "Priority: urgent" -H "Title: Coffer Error" -H "Tags: lock,warning" \
  -d "Error description here" "https://ntfy.sh/wiles-watchdog-41aa3b5cea50"
```

This is integrated into the `die()` function so every fatal error automatically sends a push notification. Non-fatal warnings (`warn()`) do NOT send ntfy notifications.

### Implementation

```bash
# Every lib/*.sh script starts with:
set -euo pipefail

COFFER_NTFY_TOPIC="https://ntfy.sh/wiles-watchdog-41aa3b5cea50"

# Shared error handler in lib/common.sh:
die() {
    echo "coffer: error: $*" >&2
    # Push urgent notification on every failure
    curl -s -H "Priority: urgent" -H "Title: Coffer Error" -H "Tags: lock,warning" \
      -d "$*" "$COFFER_NTFY_TOPIC" >/dev/null 2>&1 || true
    exit 1
}

warn() {
    echo "coffer: warning: $*" >&2
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found. Install: brew install $1"
}

require_identity() {
    local key_file="${COFFER_SESSION_KEY:-$HOME/.config/coffer/.session-key}"
    [[ -e "$key_file" ]]  || die "No identity found at ${key_file}. Run: coffer init"
    [[ -r "$key_file" ]]  || die "Identity file ${key_file} exists but is not readable by this user."
    [[ -s "$key_file" ]]  || die "Identity file ${key_file} is empty. Run: coffer init (or restore from backup)."
}
```

The real implementation in `lib/common.sh` matches this spec and is
kept minimal by design. There is intentionally no permissions check
here: the file is created mode 600 by `coffer init`, and `ensure_unlocked`
only requires readability. Tightening to a "must be exactly 600" check
added failure modes without adding security (the file is already
protected by user isolation + FileVault) and was dropped.

---

## Security Model

### Threat Model

| Threat | Mitigation |
|--------|------------|
| Disk theft (powered-off Mac) | FileVault encrypts the whole volume at rest, including `~/.config/coffer/.session-key`. Without the login password the attacker gets ciphertext only. |
| Unauthorized access from other local users on an unlocked Mac | Session-key file is mode 600, owned by the invoking user. Other local accounts can't read it; `sudo` from another admin is the weak point, same as Keychain's default ACL. |
| Process running as the same user exfiltrates the key | Accepted risk, same as Keychain on an unlocked Mac. Any malware running as the user can read the session-key file OR query Keychain. The future passphrase-encrypted identity (see [Future Work](#future-work)) would raise this bar by requiring an unlock step. |
| Network interception | No network calls. Mutagen uses SSH transport (encrypted). |
| Memory scraping | Decrypted values exist in memory briefly (shell variables, pipes). Acceptable risk for CLI tools. |
| Malicious modification of vault files | SOPS MAC detects tampering. |
| Compromised machine | Rotate keys: generate a new identity on the replacement machine, remove the compromised pubkey from `.sops.yaml`, `sops updatekeys` every vault file. |
| Shell history exposure | `coffer set` without a value argument prompts interactively. Warn in docs against passing secrets as CLI args. |
| Temp file leakage | No temp files created by coffer. SOPS `edit` creates a brief temp file with restrictive permissions (SOPS-managed). |
| Clipboard exposure | `--clip` auto-clears after 30 seconds. Optional, not default behavior. |

### Key Rotation Procedure

If a machine is compromised or decommissioned:
1. Generate a new keypair on the replacement/surviving machine
2. Remove the compromised machine's public key from `.sops.yaml`
3. Run `coffer rekey` to re-encrypt all vault files without the compromised key
4. Rotate any secrets that may have been exposed

### Identity File Security

- Location: `${COFFER_SESSION_KEY}` (default `~/.config/coffer/.session-key`)
- Content: cleartext age secret key (single line, `AGE-SECRET-KEY-...`)
- Permissions: `600` (owner read/write only)
- At-rest protection: FileVault + UNIX perms + user isolation
- Never committed to git
- Never synced between machines (Mutagen is configured to sync only `vault/`)
- Each machine has its own unique keypair; both pubkeys are listed as SOPS recipients so either machine can decrypt shared vault files.

---

## Identity and Unlock Model

### Single Source of Truth

Coffer's identity — the age secret key it uses to decrypt every vault
file — lives in **exactly one place**: the session-key file at
`${COFFER_SESSION_KEY}` (default `~/.config/coffer/.session-key`), mode
600, owned by the invoking user. Every coffer subcommand loads the key
from that file (via `ensure_unlocked`) and, if the file is missing,
dies with an actionable error telling the user to run `coffer init`.

This is "Option 2" in the April 2026 refactor. The previous design
had two parallel identity stores — the file AND a macOS Keychain entry
at service `Coffer`, account `coffer-secret-key` — which caused a
family of real bugs:

- **SSH / headless contexts failed the identity check.** macOS does
  not grant Keychain access to SSH-spawned processes by default.
  `require_identity` tested Keychain presence only, so any
  remotely-invoked coffer operation died with "No identity found"
  even when `.session-key` was present and `ensure_unlocked` would
  have happily loaded it. This manifested as silent failures in
  `save-r2-keys.sh` (cron-driven backup job) and repeated "false
  alert" incidents Bryce surfaced in session transcripts.

- **Drift.** The Keychain entry and the file could get out of sync
  (one rotated without the other), producing "works here, broken
  there" symptoms across Wiles / Verve.

- **Coupled CI footprint.** The Keychain code path required the
  `security` binary and an unlocked login keychain, which is
  unavailable in GitHub Actions or any non-interactive test runner.

The refactor removes the Keychain path entirely. `ensure_unlocked`
is now a two-branch function (env var → file), `require_identity`
checks file presence only, and `coffer init` writes only to the file.
No library code calls `security find-generic-password` /
`security add-generic-password` / `security delete-generic-password`
anymore; a structural test (`test_no_keychain_calls_in_library`)
enforces that.

### Threat-Model Equivalence

On an **unlocked Mac with the user logged in**, a cleartext file at
`~/.config/coffer/.session-key` (mode 600) provides the same effective
security as a macOS Keychain entry with the default ACL:

- Both are readable by any process running as the user.
- Neither protects against malware running as the user.
- Both are opaque to other local users (Keychain: login keychain is
  per-user; file: mode 600).
- Both are protected at rest by FileVault when the Mac is powered
  off or locked pre-login.

The Keychain wins in exactly one scenario: partition-list ACLs that
require a GUI prompt ("Always Allow") for specific binaries. Coffer
did not use this feature — it called `security` with the default ACL,
putting it at parity with a mode-600 file.

### Future Hardening: Passphrase-Encrypted Identity

If the threat model ever tightens (e.g., coffer starts holding
credentials that survive beyond the user's control, or a compliance
regime demands a separate unlock step), the next step is a
passphrase-encrypted identity file:

1. `coffer init` encrypts the age secret key with a user-chosen
   passphrase via age's scrypt KDF, writes the encrypted blob to
   `~/.config/coffer/identity.age`.
2. `coffer unlock` prompts for the passphrase, decrypts the key, and
   either (a) exports `SOPS_AGE_KEY` for the shell, or (b) writes
   `~/.config/coffer/.session-key` with mode 600 for the duration
   of the session.
3. `coffer lock` removes `.session-key` AND unsets `SOPS_AGE_KEY`
   (at that point the "lock" command becomes a real at-rest lock).

This is deferred, not planned for a specific milestone, because the
current model is sufficient for the user's single-user dev
environment and the added friction of a passphrase prompt per
shell session isn't worth the marginal security gain until the
threat model changes.

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `SOPS_AGE_KEY` | Decrypted age private key, in-memory, exported by `eval $(coffer unlock)` or any coffer subcommand that loads the file. |
| `COFFER_SESSION_KEY` | Path override for the session-key file (default `~/.config/coffer/.session-key`). Used by tests and alternative configs. |
| `COFFER_ROOT` | Override coffer directory location. |
| `EDITOR` | Editor for `coffer edit`. |

---

## Keychain Migration (historical)

### Overview
Migrate all secrets currently stored in macOS Keychain (accessed via `security find-generic-password`) to coffer. The migration is a one-time operation using a CSV export.

### Export from Keychain

```bash
# Generate CSV from known keychain entries
# (Manual process since `security` doesn't support bulk CSV export)
# Script will iterate known service names and build the CSV:

#!/usr/bin/env bash
set -euo pipefail
echo "service,account,password"
while IFS= read -r service; do
    pw=$(security find-generic-password -s "$service" -w 2>/dev/null) || continue
    acct=$(security find-generic-password -s "$service" 2>/dev/null | grep "acct" | sed 's/.*="//;s/"//')
    echo "\"$service\",\"$acct\",\"$pw\""
done <<'SERVICES'
Claude Code - DNS
Claude Code - HA Token
Claude Code - Hubitat Token
Claude Code - Access
Claude Code - Memory Sync
Claude Code - Email Sender
Claude Code - CF Tunnel SNaI
Claude Code - VoIP.ms
Claude Code - BPSMail iCloud
Claude Code - Tailscale
Claude Code - BShaCore DSM
Claude Code - NAS000 DSM
Claude Code - NAS002 DSM
Claude Code - BShaDev DSM
Claude Code - SwitchBot API
Claude Code - SwitchBot Secret
Claude Code - CF Pages Token
Claude Code - Zoho CRM Client ID
Claude Code - Zoho CRM Client Secret
Claude Code - CRM Worker Auth
Claude - 1507.systems - Zone Management
Claude - shashinka.org - Zone Management
Claude - hellgaskitchen.com - Zone Management
Claude Code - Resend HK
Claude Code - HK Email Auth
BS-IoT
Claude Code - Proxmox PVE000
Claude Code - TUG BBS
Claude Code - VoIP.ms Portal
Claude Code - VoIP.ms SIP ASTERISK
Claude Code - Zoho Client Portal ID
Claude Code - Zoho Client Portal Secret
SERVICES
```

### Import into Coffer

```bash
coffer import keychain-backup.csv
```

The import command reads the mapping file to know which category/key each service name maps to.

---

## Category Mapping

### config/keychain-mapping.yaml

This file maps macOS Keychain service names to coffer `category/key` paths.

```yaml
# Keychain service name -> coffer category/key
mappings:
  # === Cloudflare ===
  "Claude Code - DNS": cloudflare/dns-token
  "Claude Code - CF Pages Token": cloudflare/pages-token
  "Claude Code - CF Tunnel SNaI": cloudflare/tunnel-snai
  "Claude Code - Access": cloudflare/access-token
  "Claude - 1507.systems - Zone Management": cloudflare/zone-mgmt-1507systems
  "Claude - shashinka.org - Zone Management": cloudflare/zone-mgmt-shashinka
  "Claude - hellgaskitchen.com - Zone Management": cloudflare/zone-mgmt-hellgaskitchen

  # === Home Automation ===
  "Claude Code - HA Token": home-automation/home-assistant-token
  "Claude Code - Hubitat Token": home-automation/hubitat-token
  "Claude Code - SwitchBot API": home-automation/switchbot-api-token
  "Claude Code - SwitchBot Secret": home-automation/switchbot-api-secret
  "BS-IoT": home-automation/bs-iot

  # === Synology NAS ===
  "Claude Code - BShaCore DSM": synology/bshacore-dsm
  "Claude Code - NAS000 DSM": synology/nas000-dsm
  "Claude Code - NAS002 DSM": synology/nas002-dsm
  "Claude Code - BShaDev DSM": synology/bshadev-dsm

  # === Communications (VoIP, Email, Discord) ===
  "Claude Code - VoIP.ms": communications/voipms-api
  "Claude Code - VoIP.ms Portal": communications/voipms-portal
  "Claude Code - VoIP.ms SIP ASTERISK": communications/voipms-sip-asterisk
  "Claude Code - Email Sender": communications/email-sender
  "Claude Code - BPSMail iCloud": communications/bpsmail-icloud
  "Claude Code - Resend HK": communications/resend-hk
  "Claude Code - HK Email Auth": communications/hk-email-auth

  # === Zoho CRM ===
  "Claude Code - Zoho CRM Client ID": misc/zoho-crm-client-id
  "Claude Code - Zoho CRM Client Secret": misc/zoho-crm-client-secret
  "Claude Code - CRM Worker Auth": misc/crm-worker-auth
  "Claude Code - Zoho Client Portal ID": misc/zoho-client-portal-id
  "Claude Code - Zoho Client Portal Secret": misc/zoho-client-portal-secret

  # === Misc ===
  "Claude Code - Memory Sync": misc/memory-sync
  "Claude Code - Tailscale": misc/tailscale
  "Claude Code - Proxmox PVE000": misc/proxmox-pve000
  "Claude Code - TUG BBS": misc/tug-bbs
```

### Vault Category Breakdown

| Category File | Description | Keys |
|---------------|-------------|------|
| `cloudflare.yaml` | All Cloudflare API tokens, zone management, tunnel, Pages | 7 keys |
| `github.yaml` | GitHub PATs, deploy keys, app credentials | (empty initially, populated as needed) |
| `home-automation.yaml` | Home Assistant, Hubitat, SwitchBot, IoT credentials | 5 keys |
| `synology.yaml` | DSM admin credentials for all NAS devices | 4 keys |
| `communications.yaml` | VoIP.ms (API, portal, SIP), email sender, BPSMail, Resend, HK email auth | 7 keys |
| `misc.yaml` | Zoho CRM/portal, Memory Sync, Tailscale, Proxmox, TUG BBS | 7 keys |

---

## Import CSV Format

### Input Format

```csv
service,account,password
"Claude Code - DNS","","token-value-here"
"Claude Code - HA Token","admin","token-value-here"
```

- **service**: The macOS Keychain service name (used for mapping lookup)
- **account**: The account field from Keychain (informational, not used for mapping)
- **password**: The actual secret value

### Import Behavior

1. Parse CSV (handle quoted fields, commas in values)
2. For each row, look up `service` in `config/keychain-mapping.yaml`
3. If mapping found: call `set` with the mapped path and password value
4. If mapping not found: print warning, add to skipped list
5. At completion, print summary:
   ```
   Import complete:
     Imported: 30
     Skipped (no mapping): 2
       - "Unknown Service 1"
       - "Unknown Service 2"
     Errors: 0
   ```

### Post-Migration Verification

After import, run a verification pass:
```bash
coffer verify-import keychain-backup.csv
```

This decrypts each imported secret and compares it to the CSV value (done in memory, no disk writes). Reports any mismatches.

---

## Dependencies

| Tool | Version | Install | Purpose |
|------|---------|---------|---------|
| `sops` | >= 3.9.0 | `brew install sops` | Structured encryption/decryption |
| `age` | >= 1.2.0 | `brew install age` | Underlying cryptography (XChaCha20-Poly1305) |
| `yq` | >= 4.40.0 | `brew install yq` | YAML parsing and manipulation |
| `bash` | >= 5.0 | `brew install bash` (macOS ships 3.2) | Shell scripting (needs modern bash for associative arrays, etc.) |
| `mutagen` | >= 0.17.0 | `brew install mutagen` | File sync between machines |

All dependencies installable via Homebrew. No compiled code, no runtimes beyond bash.

### Version Check

`coffer` will check for minimum versions of all dependencies on every invocation (cached check, refreshed daily) and print clear upgrade instructions if any are outdated.

---

## Historical: Keychain-Based Auto-Unlock (removed 2026-04-19)

Earlier drafts of this document specified:

1. A `coffer unlock --auto` LaunchAgent that read a master passphrase
   from the macOS Keychain at boot and decrypted a passphrase-encrypted
   identity file.
2. A Verve-side `wiles-unlock` helper that popped an osascript dialog
   and sent the passphrase to Wiles via SSH.
3. A "Keychain Safety Rules" policy governing when automated code was
   allowed to touch `security find-generic-password`.

**None of this was ever implemented** (coffer shipped with a simpler
Keychain-stores-the-age-key-directly design), and even the shipped
simpler version was problematic — see "Single Source of Truth" in
[Identity and Unlock Model](#identity-and-unlock-model) for the bug
family it produced. The April 2026 refactor removed the Keychain
dependency entirely in favor of a session-key file.

If a future requirement re-introduces passphrase-based unlock, the
implementation should NOT recreate the Keychain dependency. Instead,
use age's built-in scrypt passphrase encryption (which works
cross-platform, has no macOS API quirks, and is testable in CI). See
"Future Hardening: Passphrase-Encrypted Identity" in the
[Identity and Unlock Model](#identity-and-unlock-model) section for
the proposed design.

---

## Future Work

### Bitwarden Backend (Planned)
When Bitwarden ships their AI retrieval API, add an optional backend that:
- Stores secrets in Bitwarden instead of (or in addition to) SOPS files
- Uses the Bitwarden CLI or API for encrypt/decrypt
- Maintains the same `coffer` CLI interface (swappable backend)
- Enables cloud sync as an alternative to Mutagen

### Potential Enhancements
- **`coffer audit`** -- report on secret age, detect potentially rotated tokens
- **`coffer env`** -- generate a `.env` file from a template mapping coffer paths to env var names
- **`coffer agent`** -- a background agent that brokers the identity over a Unix socket (similar to ssh-agent), so multiple processes don't each hold a copy of `SOPS_AGE_KEY` in their own environment. Most useful if/when the passphrase-encrypted identity lands (see [Identity and Unlock Model](#identity-and-unlock-model)).
- **`coffer rotate <category/key>`** -- guided rotation workflow (fetch new token from provider API where possible, update vault, verify)
- **Shell completion** -- bash/zsh completions for categories and keys
- **Touch ID integration** -- use macOS Secure Enclave via `age-plugin-se` for passphrase-less decryption on machines with Touch ID

---

## Integration with Claude Code

### Replacing Keychain Lookups
Currently, Claude Code retrieves credentials via:
```bash
security find-generic-password -s "Claude Code - DNS" -w
```

After migration, this becomes:
```bash
coffer get cloudflare/dns-token
```

### CLAUDE.md Update
After migration, update `CLAUDE.md` to replace the credential retrieval instructions:

**Before:**
```
- `security find-generic-password -s "Claude Code - DNS" -w`
```

**After:**
```
- `coffer get cloudflare/dns-token`
```

### Transition Period
During migration, both systems will work simultaneously. The keychain entries remain until coffer is verified working on both machines. Removal of keychain entries is a manual step after full verification.

---

## Appendix: SOPS Configuration Reference

### config/.sops.yaml

```yaml
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1_WILES_PUBLIC_KEY_HERE,
      age1_VERVE_PUBLIC_KEY_HERE
```

### Environment Variables

| Variable | Purpose | Set By |
|----------|---------|--------|
| `SOPS_AGE_KEY` | age private key (cleartext, in-memory) | `eval $(coffer unlock)` or `ensure_unlocked` |
| `COFFER_SESSION_KEY` | Path override for the session-key file (default `~/.config/coffer/.session-key`) | User (optional); exported by `bin/coffer` |
| `COFFER_ROOT` | Override coffer directory location | User (optional); exported by `bin/coffer` |
| `COFFER_VAULT` | Path to the vault directory (default `${COFFER_ROOT}/vault`) | Exported by `bin/coffer` |
| `COFFER_SOPS_CONFIG` | Path to `.sops.yaml` | Exported by `bin/coffer` |
| `EDITOR` | Editor for `coffer edit` | User's shell config |
