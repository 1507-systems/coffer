# coffer

Offline encrypted secrets vault CLI for developers. Uses [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) for encryption. No cloud sync, no daemon, no browser extension -- just encrypted YAML files on disk.

## How it works

Secrets are organized into categories (e.g., `cloudflare`, `github`, `home-automation`). Each category is a SOPS-encrypted YAML file. The `coffer` CLI encrypts/decrypts transparently using your age identity, which lives in `~/.config/coffer/.session-key`.

The vault data lives in a separate private repository (see below), so the open-source tool code never touches your actual secrets.

## Requirements

- macOS (tested on macOS 14+; should work on any Unix)
- [age](https://github.com/FiloSottile/age): `brew install age`
- [sops](https://github.com/getsops/sops): `brew install sops`
- [yq](https://github.com/mikefarah/yq): `brew install yq`
- git

## Setup

### 1. Clone the tool

```bash
git clone git@github.com:1507-systems/coffer.git ~/dev/coffer
# Add to PATH in your ~/.zshrc.local or ~/.zshrc:
export PATH="$HOME/dev/coffer/bin:$PATH"
```

### 2. Create your vault repo

Your encrypted secrets live in a separate private git repo. You own it; coffer never touches GitHub on your behalf except to push vault commits.

```bash
# Create a private repo (e.g., on your personal GitHub account)
gh repo create yourname/coffer-vault --private --clone=false
git clone git@github.com:yourname/coffer-vault.git ~/dev/coffer-vault
```

### 3. Point coffer at your vault

```bash
# Add to ~/.zshrc.local:
export COFFER_VAULT_ROOT=$HOME/dev/coffer-vault
```

### 4. Initialize your identity

```bash
coffer init
```

This generates an age keypair and writes the secret key to `~/.config/coffer/.session-key` (mode 600). The public key goes to `~/.config/coffer/public-key`.

### 5. Configure SOPS

Create `$COFFER_VAULT_ROOT/config/.sops.yaml` listing the age public keys authorized to decrypt your vault:

```yaml
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1your-public-key-here
```

You can have multiple recipients (multiple machines, team members). See `coffer add-recipient` and `coffer finalize-onboard` for multi-machine setup.

## Usage

```bash
coffer get  cloudflare/dns-token        # Retrieve a secret
coffer set  cloudflare/dns-token        # Set a secret (prompts for value)
coffer set  cloudflare/dns-token VALUE  # Set a secret inline
coffer list                             # List all categories and keys
coffer list cloudflare                  # List keys in one category
coffer edit cloudflare                  # Open category in $EDITOR
coffer doctor                           # Audit vault state (recipient drift, git sync)
coffer sync-pull                        # Pull latest vault changes from git
```

After every write (`set`, `edit`, `import`, `add-recipient`), coffer automatically commits and pushes the encrypted change to `$COFFER_VAULT_ROOT` origin/main. This keeps the vault in sync across machines via git rather than relying on file-level sync tools.

## Multi-machine setup

To add a second machine:

1. On the new machine: `coffer init` then `coffer onboard` (drops a pubkey file in the vault).
2. On a trusted machine: `git -C $COFFER_VAULT_ROOT pull && coffer finalize-onboard` (re-encrypts vault with the new key).
3. On the new machine: `git -C $COFFER_VAULT_ROOT pull` and test with `coffer doctor`.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `COFFER_VAULT_ROOT` | `~/dev/coffer-vault` | Path to the private vault repo root |
| `COFFER_AUTO_SYNC` | `1` (on) | Set to `0` to skip auto git commit+push |

## Session hooks

Add to your shell profile or tool hooks to auto-pull the vault at the start of each session:

```bash
coffer sync-pull 2>&1 | tail -3
```

## License

MIT. See `LICENSE` if present, or assume MIT applies.
