# Coffer - Specification

**Offline Encrypted Secrets Vault for macOS Developer Credentials**

Version: 1.0.0-draft
Created: 2026-04-07
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
12. [Keychain Migration](#keychain-migration)
13. [Category Mapping](#category-mapping)
14. [Import CSV Format](#import-csv-format)
15. [Dependencies](#dependencies)
16. [Auto-Unlock at Boot](#auto-unlock-at-boot)
17. [Remote Unlock from Verve](#remote-unlock-from-verve)
18. [Verve-Side Helper Script: wiles-unlock](#verve-side-helper-script-wiles-unlock)
19. [Keychain Safety Rules](#keychain-safety-rules)
20. [Future Work](#future-work)

---

## Overview

Coffer is an offline, encrypted secrets vault that replaces macOS Keychain as the primary store for API tokens, passwords, and developer credentials. It uses **SOPS** for structured encryption and **age** for the underlying cryptography, producing human-readable YAML files where keys are visible but values are encrypted.

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
| `~/.config/coffer/identity.txt` | Machine-local age private key (never synced, never committed) |
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

### Passphrase Protection
The age identity file (`~/.config/coffer/identity.txt`) is itself encrypted with the user's login password via age's scrypt passphrase encryption. This means:

1. The encrypted vault files on disk require the age private key to decrypt
2. The age private key requires the login password to unlock
3. No unencrypted secrets ever touch the filesystem

The passphrase is prompted once per session. The decrypted identity is held in memory only (via process substitution) and never written to a temp file.

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
- `~/.config/coffer/identity.txt` -- age private key (machine-local, passphrase-encrypted)
- `~/.config/coffer/machine-name` -- plaintext file containing "wiles" or "verve"

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

#### `coffer init`
First-time setup on a new machine.

```bash
coffer init
```

**Behavior:**
1. Check for existing identity at `~/.config/coffer/identity.txt`. If exists, abort with message.
2. Prompt for machine name (suggest based on hostname)
3. Generate a new age keypair: `age-keygen -o /dev/stdout`
4. Prompt for passphrase (login password)
5. Encrypt the private key with the passphrase: `age -p -o ~/.config/coffer/identity.txt`
6. `chmod 600 ~/.config/coffer/identity.txt`
7. Store machine name in `~/.config/coffer/machine-name`
8. **Store the master password in macOS Keychain** for auto-unlock at boot:
   ```bash
   security add-generic-password -s "Coffer" -a "coffer" -w "$passphrase" \
     -T /usr/bin/security -T /bin/bash
   ```
   This is a **one-time operation** that the user runs manually from a GUI terminal (required for Keychain ACL prompts). The `-T` flags set the partition list so that `security find-generic-password` can read it from non-interactive contexts (LaunchAgents).
9. Print the public key and instruct user to run `coffer add-recipient` on the other machine
10. If this is the first machine (no existing `.sops.yaml` recipients), create the SOPS config
11. Create vault directory and empty category files if they don't exist

**Keychain safety:** The `coffer init` step is the ONLY time coffer writes to the keychain. See [Keychain Safety Rules](#keychain-safety-rules) for the full policy.

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

### Session passphrase caching

To avoid prompting for the passphrase on every single operation, coffer uses `SOPS_AGE_KEY` environment variable approach:

1. On first `coffer` invocation in a shell session, if `SOPS_AGE_KEY` is not set:
   a. Prompt for passphrase
   b. Decrypt the identity file to a variable: `key=$(age -d ~/.config/coffer/identity.txt)`
   c. Export `SOPS_AGE_KEY="$key"` for the current process
2. Subsequent operations in the same invocation reuse the variable
3. For multi-command workflows, the user can run `eval $(coffer unlock)` which exports `SOPS_AGE_KEY` into the current shell session
4. The `coffer lock` command unsets `SOPS_AGE_KEY`

**The decrypted key only lives in shell environment variables, never on disk.**

**Headless machines (Wiles):** On dedicated headless dev machines, coffer should unlock
once at boot (via auto-unlock LaunchAgent) and stay unlocked until reboot or explicit
`coffer lock`. These machines run autonomous operations (marathon mode, cron, LaunchAgents)
and are monitored from mobile devices where re-prompting is impractical. The `coffer agent`
(future work) will hold the decrypted identity in a persistent Unix socket, surviving across
shell sessions. Until then, the auto-unlock LaunchAgent sets `SOPS_AGE_KEY` in a file at
`~/.config/coffer/.session-key` (mode 0600, owned by user) that coffer reads as a fallback
when the environment variable is not set. This file is deleted on `coffer lock` or shutdown.

**Laptops (Verve):** Session caching via environment variables is appropriate. The machine
sleeps and travels, so credentials naturally clear when the shell exits.

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
| Identity file missing | Exit 1, print: "No identity found. Run: coffer init" |
| Identity file wrong permissions | Exit 1, print: "Identity file permissions too open. Run: chmod 600 ~/.config/coffer/identity.txt" |
| Wrong passphrase | age exits non-zero, coffer propagates: "Failed to decrypt identity. Wrong passphrase?" |
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
    local id_file="${COFFER_IDENTITY:-$HOME/.config/coffer/identity.txt}"
    [[ -f "$id_file" ]] || die "No identity found. Run: coffer init"
    local perms
    perms=$(stat -f "%Lp" "$id_file")
    [[ "$perms" == "600" ]] || die "Identity file permissions too open ($perms). Run: chmod 600 $id_file"
}
```

---

## Security Model

### Threat Model

| Threat | Mitigation |
|--------|------------|
| Disk theft / unauthorized file access | All vault files encrypted with age (XChaCha20-Poly1305). Identity file passphrase-protected with scrypt. |
| Network interception | No network calls. Mutagen uses SSH transport (encrypted). |
| Memory scraping | Decrypted values exist in memory briefly (shell variables, pipes). Acceptable risk for CLI tools. |
| Malicious modification of vault files | SOPS MAC detects tampering. |
| Compromised machine | Attacker needs both the identity file AND the passphrase. Rotate keys with `coffer rekey` after compromise. |
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

- Location: `~/.config/coffer/identity.txt`
- Permissions: `600` (owner read/write only)
- Encrypted with age passphrase encryption (scrypt KDF)
- Never committed to git
- Never synced between machines
- Each machine has its own unique keypair

---

## Keychain Migration

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

## Auto-Unlock at Boot

### LaunchAgent

A LaunchAgent runs `coffer unlock --auto` at boot, which reads the master password from the macOS Keychain and decrypts the age identity without user interaction.

```xml
<!-- ~/Library/LaunchAgents/com.coffer.auto-unlock.plist -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.coffer.auto-unlock</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/bin/coffer</string>
        <string>unlock</string>
        <string>--auto</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

### `coffer unlock --auto` Behavior

1. Read the master password from Keychain: `security find-generic-password -s "Coffer" -a "coffer" -w`
2. If keychain read succeeds: decrypt the age identity and export `SOPS_AGE_KEY` (or write to a session-scoped Unix socket / agent mechanism)
3. If keychain read fails (e.g., after a macOS restore, Keychain corruption, or missing entry):
   - Send an ntfy urgent notification:
     ```bash
     curl -s -H "Priority: urgent" -H "Title: Coffer Locked" -H "Tags: lock,warning" \
       -d "Auto-unlock failed on $(hostname). Keychain read failed. Manual unlock required." \
       "https://ntfy.sh/wiles-watchdog-41aa3b5cea50"
     ```
   - Exit non-zero and wait for manual unlock
   - Do NOT attempt to fix, reset, or re-create the keychain entry

---

## Remote Unlock from Verve

When coffer is locked on Wiles and needs manual unlock, the notification and unlock flow is:

### Notification Flow

1. **ntfy urgent notification** is sent (by the failed auto-unlock or any operation that hits a locked vault)
2. The notification is received on all subscribed devices (phone, watch, Verve desktop)

### Unlock from Verve (preferred)

On Verve, a helper script `wiles-unlock` pops a **native macOS osascript password dialog** that appears over all apps (including fullscreen), collects the password, and sends it to Wiles via SSH to unlock coffer.

The osascript dialog is preferred over tmux prompts because the user is usually attached to a Claude Code session in tmux and shouldn't need to detach to type a password.

### Unlock from Frolic / iOS

The ntfy notification on iOS instructs the user to open Jump Desktop and unlock coffer on Wiles directly (type the password into the Wiles terminal).

---

## Verve-Side Helper Script: `wiles-unlock`

### Location
`~/bin/wiles-unlock` on Verve

### Purpose
Pops a native macOS password dialog and sends the password to Wiles to unlock coffer remotely. This avoids needing to detach from the current tmux/Claude Code session.

### Implementation

```bash
#!/usr/bin/env bash
set -euo pipefail

# wiles-unlock -- Pop a native macOS dialog on Verve, send password to Wiles coffer
# Installed at ~/bin/wiles-unlock on Verve

pass=$(osascript -e 'display dialog "Unlock Coffer on Wiles:" with hidden answer default answer "" buttons {"Cancel","OK"} default button "OK"' -e 'text returned of result' 2>/dev/null)

if [ -n "$pass" ]; then
  ssh wiles "coffer unlock <<< \"$pass\"" && echo "Coffer unlocked" || echo "Unlock failed"
else
  echo "Cancelled"
fi
```

### Notes
- The `osascript` dialog pops over all apps, including fullscreen windows
- The password is sent to Wiles over SSH (encrypted in transit)
- If SSH to Wiles fails, the script exits with a clear error (no silent failure)
- This script is NOT in the coffer repo (it's a Verve-local utility in `~/bin/`)

---

## Keychain Safety Rules

**NEVER touch the macOS Keychain from automated scripts or Claude Code.**

The only keychain write operation in the entire coffer system is during `coffer init`, which the user runs **manually from a GUI terminal**. This is required because:

1. Keychain ACL prompts (the "Always Allow" dialog) require a GUI session
2. The partition list (`-T` flags) must be set during creation to allow non-interactive reads
3. Programmatic keychain modification can corrupt ACLs or trigger security lockouts

### Rules

| Operation | Allowed? | Context |
|-----------|----------|---------|
| `security add-generic-password` during `coffer init` | Yes | User runs manually from GUI terminal |
| `security find-generic-password` during `coffer unlock --auto` | Yes | LaunchAgent reads at boot |
| `security find-generic-password` from any coffer command | Yes | Read-only, uses partition list set during init |
| `security add-generic-password` from Claude Code | **NEVER** | Write a script for the user to run manually |
| `security delete-generic-password` from any automated context | **NEVER** | Manual intervention only |
| Any keychain modification after init | **NEVER** | If read fails, notify and wait for manual fix |

If a keychain read fails at any point:
1. Send an ntfy urgent notification describing the failure
2. Exit non-zero with a clear error message
3. **Do not** attempt to fix, reset, re-create, or modify the keychain entry
4. Wait for the user to resolve manually (re-run `coffer init` or fix Keychain Access)

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
- **`coffer agent`** -- a background agent that caches the decrypted identity in a Unix socket (similar to ssh-agent), avoiding repeated passphrase prompts across terminal sessions
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
| `SOPS_AGE_KEY_FILE` | Path to age identity file | coffer (default) |
| `SOPS_AGE_KEY` | Decrypted age private key (in-memory) | `coffer unlock` |
| `COFFER_ROOT` | Override coffer directory location | User (optional) |
| `COFFER_IDENTITY` | Override identity file path | User (optional) |
| `EDITOR` | Editor for `coffer edit` | User's shell config |
