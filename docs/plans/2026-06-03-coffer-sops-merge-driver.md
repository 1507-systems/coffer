# Plan: coffer-aware SOPS merge driver (auto-merge concurrent vault writes)

**Status:** PROPOSED (plan only — no implementation yet)
**Date:** 2026-06-03
**Scope:** `1507-systems/coffer` (tool) + `bryce-shashinka/coffer-vault` (private data)
**Approval:** Merging/approving this PR = approval to implement.

---

## 1. Problem statement

coffer is an offline encrypted secrets vault. Secrets live in SOPS-encrypted
YAML category files under `vault/` (one file per category, e.g.
`vault/cloudflare.yaml`), each a flat map of `key: ENC[AES256_GCM,...]` entries
with a trailing `sops:` metadata block listing the age recipients and the
wrapped data key. Encryption recipients come from `config/.sops.yaml`
(`COFFER_SOPS_CONFIG`), the single `creation_rules` entry with `path_regex:
vault/.*\.yaml$`.

coffer has **no daemon**. It auto-syncs git state **only immediately before a
write** (`auto_sync_pull` in `lib/git-sync.sh`, invoked from the `set` / `delete`
/ `edit` / `import` cases in `bin/coffer`). Reads (`coffer get`) never pull, so
between writes a machine's vault can silently lag `origin/main`. This widens the
divergence window between Wiles and Verve.

### Today's incident (2026-06-03) — the motivating example

1. On **Verve**, Bryce ran `coffer set <some/key>`. That re-encrypted a category
   file, committed, and pushed to `origin/main` (`auto_sync_push`).
2. Meanwhile on **Wiles**, a `coffer set` touched a **different key in the same
   category file**, based on the same parent commit (before Verve's push).
3. Both edits changed the same encrypted file. The ciphertext is opaque
   AES-GCM blobs plus a MAC over the whole document — there is no line-level
   structure git can reconcile. When Wiles' `auto_sync_pull` ran
   `git pull --rebase origin main`, git tried a 3-way text merge of the
   encrypted blob, could not resolve it, and the rebase conflicted.
4. `auto_sync_pull` does exactly what it is written to do on conflict: it runs
   `git rebase --abort` and `die()`s loudly (see the `pull --rebase failed
   (conflict in encrypted vault?)` branch in both `lib/git-sync.sh` and
   `cmd_refresh` in `bin/coffer`).
5. Recovery was manual: `git reset --hard origin/main` on Wiles, then re-apply
   the lost `set`.

Two **logically non-conflicting writes** (different keys) produced a hard stop
and data-loss risk, purely because they landed in the same ciphertext file.
This is the residual concurrency hole the April-2026 push-rejection hardening
(`auto_sync_pull` + `preflight_recipient_check`) did **not** close: that work
shrank the *non-fast-forward* window but cannot make git 3-way-merge ciphertext.

### Goal

When two writes touch the same category file but **different keys**, the pull
should **auto-merge** (union of both writes), re-encrypt to the **current**
recipients, and continue — with **zero** plaintext ever touching disk, git
objects, stdout, or logs. Only a genuine same-key-different-value collision
should surface as a real conflict, loudly.

---

## 2. How git merge drivers work

git supports per-path custom merge drivers, configured in two halves:

### a) `.gitattributes` (committed in the vault repo)

```
# bryce-shashinka/coffer-vault/.gitattributes
vault/**         merge=coffer-sops
config/.sops.yaml merge=coffer-sops-recipients
```

`vault/**` routes every category file through the named merge driver
`coffer-sops`. `.gitattributes` **is** tracked content, so it travels with the
repo to every clone. (See §4 for why `config/.sops.yaml` gets its own,
deliberately-non-union driver.)

### b) `git config merge.coffer-sops.driver` (per-clone, NOT cloned)

```
git config merge.coffer-sops.driver \
  'coffer merge-driver %O %A %B %L %P'
git config merge.coffer-sops.name \
  'coffer SOPS-aware union merge of encrypted vault category files'
```

Critically, **`.git/config` is local to each clone and is never transmitted by
`git clone`/`fetch`/`pull`**. So `.gitattributes` naming a driver that the local
`.git/config` does not define means git silently falls back to the default
binary/text merge — i.e. the exact failure we have today. The driver definition
must therefore be installed **per machine** (§6).

### Placeholders git substitutes into the driver command

| token | meaning |
|-------|---------|
| `%O`  | path to a temp file with the **base** (merge ancestor) version ("original") |
| `%A`  | path to a temp file with **our** version; **the driver writes the merged result back here** |
| `%B`  | path to a temp file with **their** version |
| `%L`  | conflict-marker size (git's `conflict-marker-size`; passed through for completeness) |
| `%P`  | the **pathname** in the work tree being merged (e.g. `vault/cloudflare.yaml`) — used for logging context and `--filename-override` so `.sops.yaml` `path_regex` matching still works |

Contract: the driver **reads** `%O`/`%A`/`%B`, **overwrites `%A`** with the
merged content, and **exits 0** for a clean merge or **non-zero** to signal an
unresolved conflict (git then leaves `%A` in place and marks the path
conflicted). This is invoked by git during `merge`, `rebase`, `stash pop`,
`cherry-pick` — including the `git pull --rebase` inside `auto_sync_pull`.

---

## 3. The driver algorithm (`coffer merge-driver`)

A new coffer subcommand `coffer merge-driver %O %A %B %L %P`, sourced from a new
`lib/merge-driver.sh` (mirroring the existing `lib/*.sh` one-function-per-file
convention). It reuses `common.sh` (`ensure_unlocked`, `run_sops`, `die`,
`COFFER_SOPS_CONFIG`) and the same `sops decrypt --output-type json` /
`sops encrypt --input-type json --output-type yaml` pattern already used in
`lib/set.sh`.

```
cmd_merge_driver(base=%O ours=%A theirs=%B marker_size=%L path=%P):

  0. require_cmd sops; require_cmd jq; ensure_unlocked
     # The merging machine MUST hold the age private key (same precondition
     # as any coffer read/write). If SOPS_AGE_KEY can't be loaded -> exit 1
     # (real conflict, surfaced loudly) rather than corrupting the file.

  1. Decrypt all three sides to JSON, IN MEMORY (see §5 for the secure-temp
     discipline):
        base_json   = sops decrypt --output-type json  <base>     (or "{}" if base is empty/new)
        ours_json   = sops decrypt --output-type json  <ours>
        theirs_json = sops decrypt --output-type json  <theirs>
     # Drop the "sops" metadata key from each decrypted map before merging;
     # we never merge SOPS metadata, we re-derive it on re-encrypt.

  2. Three-way merge the key MAPS (not text). For the union of all keys K:
        - in neither ours nor theirs (deleted both)     -> absent (deleted)
        - unchanged on one side, changed/added on other -> take the changed side
        - added on exactly one side (not in base)       -> take it
        - deleted on one side, unchanged on the other   -> delete (honor the deletion)
        - deleted on one side, CHANGED on the other     -> REAL CONFLICT (delete-vs-modify)
        - present on both sides with DIFFERENT values,
          and at least one differs from base            -> REAL CONFLICT
        - present on both with the SAME value           -> take it (no conflict)
     Key renames are just "delete old key + add new key" at the map level and
     fall out of the above rules automatically (no special-casing needed; a
     rename that collides with a concurrent edit of the same source key
     surfaces as a delete-vs-modify conflict, which is correct).

  3. If ANY real conflict was found:
        - Emit to STDERR a list of the conflicting KEY NAMES only (never values).
        - Do NOT write a merged %A.
        - exit 1  -> git marks vault/<cat>.yaml conflicted; auto_sync_pull's
          existing die() path fires and Bryce resolves manually.
     This guarantees the driver NEVER silently picks a winner on a true
     collision.

  4. Clean merge: re-encrypt the merged JSON map back to %A using the CURRENT
     config/.sops.yaml recipients:
        merged_json | sops encrypt --filename-override "<path>" \
            --input-type json --output-type yaml > <ours/%A>
     Using --filename-override "$path" makes SOPS match the
     `vault/.*\.yaml$` creation_rule and pull recipients from the live
     COFFER_SOPS_CONFIG — exactly as lib/set.sh does. This means the merged
     file is ALWAYS encrypted to the current recipient set, which ALSO
     auto-heals recipient drift (the original April-2026 lockout bug) as a
     free side effect of every merge.

  5. exit 0  -> git accepts %A as the resolved content, rebase/merge continues.
```

Why map-level and not text-level: SOPS YAML has no stable line identity for a
3-way text merge (re-encryption changes IVs/MAC for unrelated keys), so the only
correct merge unit is the decrypted **key→value map**. jq does the set algebra
on JSON objects; we never hand-parse decrypted YAML (same rationale as the
existing code's "all vault operations use JSON" comment in `lib/set.sh`).

---

## 4. Edge cases

1. **`config/.sops.yaml` must NOT use the union driver.** A recipient-list
   change is a security-relevant intent, not a data union. `.gitattributes`
   routes it to a **separate** driver `coffer-sops-recipients` whose policy is:
   if both sides changed the recipient list and they differ, **conflict loudly**
   (exit 1) — never silently union recipients (silently unioning could
   re-admit a removed/rotated key). If only one side changed it, take that side
   (trivial fast-forward, which git handles without the driver anyway). v1 may
   implement this as "always conflict on true divergence" and let Bryce resolve;
   a later refinement could union-add but never union-remove. Either way it is
   explicitly **out of scope** for the `vault/**` union driver.

2. **add/add of a brand-new category file** (e.g. both machines create
   `vault/newcat.yaml`): base `%O` is empty/absent. Treat missing base as
   `{}`; the algorithm in §3 then unions both sides' keys. If the two new files
   share a key with different values -> real conflict per the same-key rule.

3. **Deletion vs modification.** A whole-file delete on one side vs content
   change on the other is git's standard delete/modify conflict and surfaces
   normally (the driver is only invoked when both sides have content). A
   *key*-level delete-vs-modify within a file is handled in step 2 as a real
   conflict.

4. **Empty / never-encrypted files.** Files with no `sops:` block (uninitialized
   category) are not yet ciphertext; if such a file reaches the driver, decrypt
   of that side yields `{}` and it merges as an empty map. (Mirrors the
   `grep -q '^sops:'` skip already used in `lib/add-recipient.sh`.)

5. **Age private key precondition.** The merging machine must hold the age
   secret (the `~/.config/coffer/.session-key` that `ensure_unlocked` loads). If
   it cannot decrypt, the driver exits 1 (loud conflict) rather than guessing —
   no different from the precondition on every other coffer operation.

6. **Non-vault files.** The driver is scoped strictly by `.gitattributes`
   (`vault/**` only). Tool-repo files, `README.md`, `PROJECT_LOG.md`, etc. use
   git's default merge. `config/.sops.yaml` uses the dedicated recipients driver
   above. Nothing else is touched.

---

## 5. Security: no plaintext leakage

Decrypted secrets exist only transiently, in memory or in locked-down temp, and
never anywhere durable:

- **No plaintext to disk unprotected.** Decrypt into shell variables / process
  substitution where possible. Where a temp file is unavoidable (sops needs a
  path for some operations), create it with `umask 077` in a per-invocation
  `mktemp -d` under `$TMPDIR` (or, where available, a RAM-backed dir), and
  register a `trap 'shred -u <files> 2>/dev/null || rm -f <files>; rmdir <dir>'
  EXIT INT TERM` **before** writing any plaintext. On macOS (no `shred`), use
  `rm -fP` (overwrite) as the fallback, with a documented caveat that FileVault
  is the real at-rest guarantee (consistent with coffer's existing threat model
  in `common.sh` / SPEC.md, which dropped Keychain in favor of FileVault + mode
  600).
- **No plaintext to git objects.** The only thing ever written to `%A` (which
  git turns into a tree object) is the **re-encrypted** SOPS YAML. The merged
  JSON is piped directly into `sops encrypt`; its stdout is the ciphertext that
  lands in `%A`. Plaintext JSON is never the content of `%A`.
- **No plaintext to stdout.** The driver prints only status/diagnostics to
  **stderr**; on conflict it prints **key names only**, never values. stdout is
  unused by the merge-driver contract.
- **No plaintext to logs.** `log`/`warn`/`die` (from `common.sh`) are passed key
  names and counts only. The `coffer_ntfy_urgent` path (fired by `die`) must
  likewise carry only key names. **Explicit rule:** no `set -x`, no echoing of
  `*_json` variables, no including decrypted values in any error string.
- **Defense in depth:** run the decrypt/merge in a subshell so the plaintext
  vars fall out of scope on return; keep the `SOPS_AGE_KEY` handling identical
  to `run_sops` (already in `common.sh`).

A pre-merge security checklist (grep the driver for `echo "$*_json"`, `set -x`,
`tee`, `>`-to-non-temp) is part of the test/review gate (§8).

---

## 6. Installation / distribution

Because `merge.<name>.driver` lives in `.git/config` and is **not cloned**,
coffer must register it per machine. Proposed subcommand:

```
coffer install-merge-driver
```

It does, idempotently, in `COFFER_VAULT_ROOT`:

1. `git config merge.coffer-sops.driver 'coffer merge-driver %O %A %B %L %P'`
   and `merge.coffer-sops.name '...'`.
2. `git config merge.coffer-sops-recipients.driver '...'` (the recipients
   policy driver from §4.1) and its `.name`.
3. Ensure `.gitattributes` exists in the vault repo with the two lines from §2a;
   if missing/incomplete, write and **stage** it (it gets committed via the
   normal `auto_sync_push` path, since it lives under the repo root — note
   `auto_sync_push` currently stages only `config/.sops.yaml` and `vault/`, so
   either commit `.gitattributes` explicitly in this subcommand or widen the
   staging allow-list to include it; decide in implementation).
4. Verify `coffer` resolves on `PATH` for non-interactive git invocations
   (git runs the driver in a minimal shell). If `coffer` is not on the default
   non-interactive `PATH`, register an **absolute** path to the `coffer` bin in
   the driver command instead of the bare name.

**Auto-install hooks** so it is never forgotten:
- Call `install-merge-driver` (idempotent, near-zero cost) at the **top of
  `auto_sync_pull`** the first time per repo (guard with a sentinel like
  `git config --get merge.coffer-sops.driver`), and/or
- Add it to the **SessionStart** hook that already runs `coffer refresh`.

**Must land on BOTH Wiles and Verve.** Rollout (§9) explicitly runs it on each
machine and verifies via `git config --get merge.coffer-sops.driver`.

---

## 7. Integration with `auto_sync_pull`

No structural change to control flow — once the driver is registered, the
existing `git pull --rebase origin main` inside `auto_sync_pull` (and inside
`cmd_refresh`) will invoke `coffer merge-driver` for any conflicting
`vault/**` file and auto-resolve the union case. The existing
`pull --rebase failed -> rebase --abort -> die()` branch then only fires for
**true conflicts** (same-key/different-value, delete-vs-modify, or a real
`.sops.yaml` divergence) — which is exactly when a human should be involved.

Net effect: the `set`/`delete`/`edit`/`import` flow that today dies on
concurrent different-key writes will instead union them transparently and
proceed, re-encrypted to current recipients.

---

## 8. Testing

A new `tests/test-merge-driver.sh` (or new functions in the existing
`tests/run-tests.sh`, reusing its `assert_eq`/`assert_contains`/`assert_exit_code`
helpers and `setup_test_env`/`teardown_test_env`, with `COFFER_AUTO_SYNC=0` and
a throwaway age keypair + sandbox vault):

1. **Clean union (the headline case).** Sandbox vault repo; commit a base
   `vault/test.yaml` with key `seed`. Branch `a`: `set test/keyA=valA`. Branch
   `b` off base: `set test/keyB=valB`. Register the driver; `git rebase a` onto
   `b` (or merge). **Assert:** rebase exits 0, `coffer get test/keyA == valA`
   AND `test/keyB == valB` AND `test/seed` intact, and the file's `sops:`
   recipient block equals the current `config/.sops.yaml` recipients.

2. **True conflict surfaces loudly.** Both branches `set test/keyX` to
   *different* values. Merge. **Assert:** non-zero exit, the path is left
   conflicted, stderr mentions `keyX`, and **no value strings** appear in any
   output. (Negative test for §5.)

3. **Recipient-drift heal.** Encrypt one branch's file to a STALE recipient set
   (drop a key from `.sops.yaml` before that commit), keep current recipients on
   the other side, do a clean different-key union. **Assert:** merged `%A` is
   encrypted to the **current** recipient set (every current recipient can
   decrypt), proving §3.4 auto-heal.

4. **add/add new category.** Both branches create `vault/fresh.yaml` with
   disjoint keys (empty base). **Assert:** union of keys; same-key/diff-value
   variant conflicts.

5. **No-plaintext-leak guard.** Static check: grep the driver source for
   `set -x`, value-echoing, and non-temp redirects; runtime check: run a merge
   with stdout+stderr captured and assert no known plaintext token appears.

6. **`.sops.yaml` driver.** Divergent recipient edits on both sides ->
   conflict, not silent union.

All tests run offline with `COFFER_AUTO_SYNC=0` (no network, no real origin),
consistent with the existing harness. Subject to the repo's fresh-eyes-review +
smoke-test-on-target-machine-class gate before commit.

---

## 9. Rollout steps

1. Implement `lib/merge-driver.sh` (`cmd_merge_driver`), wire `merge-driver` and
   `install-merge-driver` into the `bin/coffer` dispatcher `case`, update
   `usage()`.
2. Add tests (§8); pass locally on macOS (Verve **and** Wiles machine class).
3. fresh-eyes-review + security review focused on §5.
4. PR against `1507-systems/coffer`; merge.
5. `git pull` the tool repo on **Wiles** and **Verve**.
6. On **each** machine: `coffer install-merge-driver`, then verify
   `git config --get merge.coffer-sops.driver` is set and `cat
   $COFFER_VAULT_ROOT/.gitattributes` shows the routing lines.
7. Commit `.gitattributes` to `coffer-vault` once (lands via the install
   subcommand's stage+`auto_sync_push`, or an explicit commit).
8. Validate live: stage a real different-key concurrent write across the two
   machines (a deliberate diverge) and confirm it auto-merges instead of dying.

### Complementary background-pull safety net (separate, not a replacement)

The merge driver handles the **residual concurrent-write** case. It does **not**
replace shrinking the divergence window in the first place. A separate, smaller
piece of work (tracked independently) should add a **launchd/login-item**
running `git -C $COFFER_VAULT_ROOT pull --rebase --autostash` on a short
interval (e.g. every few minutes) on both machines, so reads see fresher state
and the two machines rarely diverge far. With the merge driver installed, that
background `--rebase` becomes safe (it auto-unions) instead of a conflict
generator. The two are layered: **background pull** narrows the window;
**merge driver** cleanly resolves whatever still collides.

---

## 10. Open questions / risks for Bryce

1. **Auto-install trigger.** Register the driver lazily inside `auto_sync_pull`
   (zero new moving parts) or explicitly in the SessionStart hook (more visible)
   — or both? Lazy-in-pull means a brand-new clone's *first* pull still runs
   without the driver until the install line executes; acceptable?
2. **`coffer` on the non-interactive `PATH`.** git runs the driver in a minimal
   shell. Should the driver command use the bare `coffer` (relies on PATH) or an
   **absolute** path baked at install time (robust but machine-specific in
   `.git/config`, which is fine since `.git/config` is per-clone anyway)?
   Recommendation: absolute path.
3. **`.sops.yaml` policy depth (§4.1).** Is "conflict on any true divergence"
   acceptable for v1, or do you want union-add-but-never-remove now?
4. **macOS secure-temp.** No `shred`; rely on FileVault + `rm -fP` + mode-077
   temp (consistent with coffer's existing FileVault-based threat model)? Or
   require a RAM disk for the merge temp?
5. **Conflict UX.** On a true conflict the file is left as SOPS-conflicted (git
   markers inside ciphertext are useless to read). Should the driver instead, on
   conflict, write a **decrypted-to-a-locked-temp side file** with both values
   for the conflicting keys so Bryce can actually see them — at the cost of a
   plaintext temp file (mode 600, shredded on resolve)? Trade-off: usability vs
   the §5 no-plaintext-on-disk rule. Default plan keeps the strict rule (key
   names only).
6. **Background-pull interval & autostash safety.** What interval, and is
   `--autostash` acceptable given coffer's existing aversion to autostash on a
   dirty encrypted tree (noted in `auto_sync_pull`)? The safety net should
   probably also refuse to run when the tree is dirty, mirroring `cmd_refresh`.

---

*Co-authored plan; implementation gated on approval of this PR.*
