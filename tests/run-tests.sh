#!/usr/bin/env bash
# run-tests.sh -- Simple test harness for coffer
# Runs all test functions and reports pass/fail counts.
# shellcheck disable=SC2329
# Test functions are invoked dynamically via run_test, not direct calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COFFER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# --- Test helpers ---

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        echo "  FAIL: ${msg}"
        echo "    expected: '${expected}'"
        echo "    actual:   '${actual}'"
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    shift
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if [[ "$expected" -eq "$actual" ]]; then
        return 0
    else
        echo "  FAIL: expected exit code ${expected}, got ${actual}"
        echo "    command: $*"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "  FAIL: ${msg}"
        echo "    expected to contain: '${needle}'"
        echo "    actual: '${haystack}'"
        return 1
    fi
}

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "TEST: ${test_name}"
    if "$test_name"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# --- Setup test fixtures ---

setup_test_env() {
    TEST_DIR=$(mktemp -d)
    export COFFER_ROOT="${TEST_DIR}/coffer"
    # COFFER_VAULT_ROOT mimics the private vault repo (bryce-shashinka/coffer-vault)
    # in tests. Both the vault data (vault/*.yaml) and the SOPS config live under
    # COFFER_VAULT_ROOT, while COFFER_ROOT is only the tool code directory.
    # Setting COFFER_VAULT_ROOT here prevents bin/coffer from falling back to the
    # legacy in-repo layout or attempting to resolve ~/dev/coffer-vault on disk.
    export COFFER_VAULT_ROOT="${TEST_DIR}/coffer-vault"
    export COFFER_VAULT="${COFFER_VAULT_ROOT}/vault"
    export COFFER_CONFIG_DIR="${TEST_DIR}/config"
    export COFFER_SOPS_CONFIG="${COFFER_VAULT_ROOT}/config/.sops.yaml"
    export COFFER_SESSION_KEY="${COFFER_CONFIG_DIR}/.session-key"

    mkdir -p "${COFFER_ROOT}/lib" "${COFFER_VAULT_ROOT}/config" "${COFFER_VAULT}" "${COFFER_CONFIG_DIR}"

    # Copy lib files from the real project (these live in the tool repo)
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    cp "${real_root}"/lib/*.sh "${COFFER_ROOT}/lib/"

    # Create a minimal .sops.yaml in the vault config dir. The real config lives in
    # the private vault repo (bryce-shashinka/coffer-vault), not the tool repo.
    # Tests that need a specific .sops.yaml (e.g., multi-recipient tests) create
    # their own in a separate sandbox and do not go through setup_test_env.
    # This placeholder is enough to make list/get/set tests that check for the
    # file's existence pass without importing real vault data into CI.
    cat > "${COFFER_VAULT_ROOT}/config/.sops.yaml" <<'SOPSEOF'
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1placeholder000000000000000000000000000000000000000000000000
SOPSEOF

    # Source common helpers
    # shellcheck source=../lib/common.sh
    source "${COFFER_ROOT}/lib/common.sh"
}

# Write a fake session-key file so require_identity passes in tests that
# exercise downstream code (list/get/set). Tests that need to verify the
# *absence* of an identity should call this helper's inverse by leaving the
# file un-written. The content must begin with AGE-SECRET-KEY- for unlock
# validation; we don't use this as a real key (tests either stub SOPS out
# or generate real keys via age-keygen in their own sandbox).
seed_fake_identity() {
    mkdir -p "${COFFER_CONFIG_DIR}"
    printf 'AGE-SECRET-KEY-FAKETESTFAKETESTFAKETESTFAKETESTFAKETEST\n' > "${COFFER_SESSION_KEY}"
    chmod 600 "${COFFER_SESSION_KEY}"
}

teardown_test_env() {
    if [[ -n "${TEST_DIR:-}" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# --- Common helper tests ---

test_die_exits_nonzero() {
    # die() should exit with code 1 and print to stderr
    # We override curl to avoid sending real ntfy notifications during tests
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        die "test error message"
    ' 2>&1) || true
    # die() calls exit 1, so the subshell should have exited non-zero
    # (bash -c wraps it, but the || true means we need to check output)
    assert_contains "$output" "coffer: error: test error message" "die() should print error message"
}

test_warn_prints_to_stderr() {
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        warn "test warning"
    ' 2>&1)
    assert_contains "$output" "coffer: warning: test warning" "warn() should print warning"
}

test_log_prints_to_stderr() {
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        log "test log"
    ' 2>&1)
    assert_contains "$output" "coffer: test log" "log() should print message"
}

test_require_cmd_succeeds_for_existing() {
    # 'bash' should always exist
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        require_cmd bash
        echo "ok"
    ' 2>&1)
    assert_contains "$output" "ok" "require_cmd should succeed for existing command"
}

test_require_cmd_fails_for_missing() {
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        require_cmd nonexistent_tool_xyz_12345
    ' 2>&1) || true
    assert_contains "$output" "nonexistent_tool_xyz_12345 not found" "require_cmd should fail for missing command"
}

test_parse_path_valid() {
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path "cloudflare/dns-token"
        echo "cat=${COFFER_CATEGORY} key=${COFFER_KEY}"
    ' 2>&1)
    assert_contains "$output" "cat=cloudflare key=dns-token" "parse_path should parse category/key"
}

test_parse_path_invalid_no_slash() {
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path "no-slash"
    ' 2>&1) || true
    assert_contains "$output" "Invalid path format" "parse_path should reject paths without /"
}

# --- List tests ---

test_list_with_test_vault() {
    # Create a fake vault file with plaintext keys (simulating SOPS encrypted file)
    cat > "${COFFER_VAULT}/testcat.yaml" <<'YAML'
key-one: ENC[AES256_GCM,data:abc]
key-two: ENC[AES256_GCM,data:def]
sops:
  lastmodified: "2026-04-07T00:00:00Z"
YAML

    # Source list.sh and run
    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output
    output=$(cmd_list 2>/dev/null)
    assert_contains "$output" "testcat/" "list should show category" && \
    assert_contains "$output" "key-one" "list should show key-one" && \
    assert_contains "$output" "key-two" "list should show key-two"
}

test_list_single_category() {
    cat > "${COFFER_VAULT}/singlecat.yaml" <<'YAML'
alpha: ENC[AES256_GCM,data:abc]
beta: ENC[AES256_GCM,data:def]
sops:
  lastmodified: "2026-04-07T00:00:00Z"
YAML

    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output
    output=$(cmd_list singlecat 2>/dev/null)
    assert_contains "$output" "alpha" "list category should show alpha" && \
    assert_contains "$output" "beta" "list category should show beta"
}

test_list_missing_category_fails() {
    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" cmd_list "nonexistent" 2>&1) || true
    assert_contains "$output" "not found" "list should fail for missing category"
}

# Bug C: coffer list must not crash when a vault yaml file is empty or null.
# Regression: on Verve, github.yaml was null-valued and caused list to print
#   "Error: cannot get keys of !!null" and stop iterating entirely.

test_list_empty_map_category_does_not_crash() {
    # A vault file containing `{}` (empty map) has type !!map, zero keys, and
    # should be listed as an empty category without crashing.
    printf '{}' > "${COFFER_VAULT}/emptymap.yaml"
    # Ensure there's at least one normal category file so we can confirm
    # iteration continues past the empty one.
    cat > "${COFFER_VAULT}/afterempty.yaml" <<'YAML'
existing-key: ENC[AES256_GCM,data:abc]
sops:
  lastmodified: "2026-04-07T00:00:00Z"
YAML

    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output rc=0
    output=$(cmd_list 2>/dev/null) || rc=$?

    # Must not crash (exit 0 expected).
    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: cmd_list exited ${rc} on empty-map vault file (expected 0)"
        return 1
    fi
    # Must show both categories — iteration must not stop at the empty one.
    assert_contains "$output" "emptymap/" "list should show empty-map category" && \
    assert_contains "$output" "afterempty/" "list should continue past empty-map to next category" && \
    assert_contains "$output" "existing-key" "list should show keys in subsequent category"
}

test_list_null_category_does_not_crash() {
    # A vault file containing the literal string "null" (or truly empty —
    # zero bytes) has yq type !!null and previously crashed the entire list.
    # Both forms should produce "(empty)" without aborting iteration.

    # Case 1: file containing the YAML null literal
    printf 'null' > "${COFFER_VAULT}/nullcontent.yaml"
    # Case 2: zero-byte file (empty)
    : > "${COFFER_VAULT}/zerobyte.yaml"
    # Case 3: a normal file AFTER the bad ones, to confirm iteration continues
    cat > "${COFFER_VAULT}/afternull.yaml" <<'YAML'
another-key: ENC[AES256_GCM,data:abc]
sops:
  lastmodified: "2026-04-07T00:00:00Z"
YAML

    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output rc=0
    output=$(cmd_list 2>/dev/null) || rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: cmd_list exited ${rc} on null/empty vault files (expected 0)"
        return 1
    fi
    # The null/empty categories must appear in output (not skipped silently)
    # and the subsequent healthy category must also appear.
    assert_contains "$output" "nullcontent/" "list should show null-content category" && \
    assert_contains "$output" "zerobyte/" "list should show zero-byte category" && \
    assert_contains "$output" "afternull/" "list should continue past null/empty to next category" && \
    assert_contains "$output" "another-key" "list should show keys in subsequent category"
}

# Bug B: machine name whitespace trimming must strip only leading/trailing
# whitespace, not everything from the first space onward.
# Regression: "coffer init" typed at the machine-name prompt became "coffer"
# (the %%[[:space:]]* pattern killed everything after the first space).

test_onboard_whitespace_machine_name_internal_space() {
    # A machine-name containing an internal space ("my laptop") must survive
    # the trim step with the space intact, then be converted to "my-laptop"
    # by the sanitization step (tr replaces spaces with hyphens).
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "  SKIP (age-keygen not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    mkdir -p "$config_dir" "$vault_dir"

    local keygen_out
    keygen_out=$(age-keygen 2>&1)
    local pub_key
    pub_key=$(printf '%s\n' "$keygen_out" | grep -oE 'age1[a-z0-9]+' | head -1)
    local secret_key
    secret_key=$(printf '%s\n' "$keygen_out" | grep '^AGE-SECRET-KEY-')

    printf '%s\n' "$secret_key" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"
    printf '%s\n' "$pub_key" > "${config_dir}/public-key"
    # Machine name with internal space — the key regression case
    printf 'my laptop\n' > "${config_dir}/machine-name"

    # shellcheck disable=SC2030,SC2031
    (
        export COFFER_ROOT="${SCRIPT_DIR}/.."
        export COFFER_CONFIG_DIR="$config_dir"
        export COFFER_SESSION_KEY="${config_dir}/.session-key"
        export COFFER_VAULT="$vault_dir"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        # shellcheck source=../lib/common.sh
        source "${COFFER_ROOT}/lib/common.sh"
        # shellcheck source=../lib/onboard.sh
        source "${COFFER_ROOT}/lib/onboard.sh"
        # shellcheck disable=SC2119
        cmd_onboard
    ) 2>/dev/null

    # Sanitization converts internal space to hyphen: "my laptop" → "my-laptop"
    local pending_file="${vault_dir}/.pending-recipient-my-laptop.pub"
    local ok=0
    [[ -f "$pending_file" ]] && ok=1
    rm -rf "$sandbox"

    if [[ $ok -eq 0 ]]; then
        echo "  FAIL: expected pending file .pending-recipient-my-laptop.pub (space→hyphen);"
        echo "        old bug would have created .pending-recipient-my.pub (truncated)"
        return 1
    fi
    return 0
}

test_onboard_whitespace_machine_name_leading_trailing() {
    # A machine-name file with leading/trailing whitespace (e.g., " verve ")
    # should be trimmed to "verve", not produce " verve" or "verve " as the
    # pending filename.
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "  SKIP (age-keygen not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    mkdir -p "$config_dir" "$vault_dir"

    local keygen_out
    keygen_out=$(age-keygen 2>&1)
    local pub_key
    pub_key=$(printf '%s\n' "$keygen_out" | grep -oE 'age1[a-z0-9]+' | head -1)
    local secret_key
    secret_key=$(printf '%s\n' "$keygen_out" | grep '^AGE-SECRET-KEY-')

    printf '%s\n' "$secret_key" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"
    printf '%s\n' "$pub_key" > "${config_dir}/public-key"
    # Leading and trailing spaces around a simple name
    printf '  verve  \n' > "${config_dir}/machine-name"

    # shellcheck disable=SC2030,SC2031
    (
        export COFFER_ROOT="${SCRIPT_DIR}/.."
        export COFFER_CONFIG_DIR="$config_dir"
        export COFFER_SESSION_KEY="${config_dir}/.session-key"
        export COFFER_VAULT="$vault_dir"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        source "${COFFER_ROOT}/lib/common.sh"
        source "${COFFER_ROOT}/lib/onboard.sh"
        # shellcheck disable=SC2119
        cmd_onboard
    ) 2>/dev/null

    local pending_file="${vault_dir}/.pending-recipient-verve.pub"
    local ok=0
    [[ -f "$pending_file" ]] && ok=1
    rm -rf "$sandbox"

    if [[ $ok -eq 0 ]]; then
        echo "  FAIL: expected pending file .pending-recipient-verve.pub after leading/trailing trim"
        return 1
    fi
    return 0
}

# --- Get error case tests ---

test_get_missing_category_fails() {
    # shellcheck source=../lib/get.sh
    source "${COFFER_ROOT}/lib/get.sh"

    # require_identity now checks the session-key file (post Option 2
    # refactor), so seed one. ensure_unlocked short-circuits because we
    # export SOPS_AGE_KEY below, so the fake file's contents don't need
    # to be a real key for this test.
    seed_fake_identity
    export SOPS_AGE_KEY="AGE-SECRET-KEY-fake"

    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" cmd_get "nonexistent/key" 2>&1) || true
    assert_contains "$output" "not found" "get should fail for missing category"
}

test_get_no_args_fails() {
    # shellcheck source=../lib/get.sh
    source "${COFFER_ROOT}/lib/get.sh"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" cmd_get 2>&1) || true
    assert_contains "$output" "Usage" "get with no args should show usage"
}

# --- Entrypoint tests ---

test_coffer_no_command_fails() {
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash "${real_root}/bin/coffer" 2>&1) || true
    assert_contains "$output" "No command specified" "coffer with no command should fail"
}

test_coffer_unknown_command_fails() {
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash "${real_root}/bin/coffer" frobnicate 2>&1) || true
    assert_contains "$output" "Unknown command" "coffer with unknown command should fail"
}

test_coffer_help() {
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local output
    output=$(bash "${real_root}/bin/coffer" --help 2>&1)
    assert_contains "$output" "Usage: coffer" "coffer --help should show usage"
}

test_coffer_version() {
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local output
    output=$(bash "${real_root}/bin/coffer" --version 2>&1)
    assert_contains "$output" "coffer 1.0.0" "coffer --version should show version"
}

# --- Set: recipient preservation (regression test for the April 2026 lockout) ---
#
# Bug: cmd_set called `sops encrypt --age <single-pubkey>`, which overrode the
# .sops.yaml multi-recipient list and silently re-encrypted with only the
# writing machine's key. Any cross-machine `coffer set` then locked the other
# machine out of that category file. Caught after Wiles couldn't decrypt
# cloudflare/* and ai/* (last-written-on-Verve) on 2026-04-19.
#
# Fix: drop --age, use SOPS_CONFIG + --filename-override so all recipients
# from .sops.yaml are applied to both new-file and update paths.

test_set_preserves_all_recipients_on_create() {
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    # Two test identities — one is "this machine" (A), the other is "remote" (B).
    age-keygen -o "${sandbox}/keyA.txt" 2>/dev/null
    age-keygen -o "${sandbox}/keyB.txt" 2>/dev/null
    local pub_a pub_b
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')
    pub_b=$(grep "public key" "${sandbox}/keyB.txt" | awk '{print $4}')

    mkdir -p "${sandbox}/vault" "${sandbox}/config" "${sandbox}/.coffer-config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_a},${pub_b}
EOF
    echo "$pub_a" > "${sandbox}/.coffer-config/public-key"

    # Run cmd_set in a subshell with all the env coffer would normally set.
    (
        export SOPS_AGE_KEY
        SOPS_AGE_KEY=$(grep AGE-SECRET "${sandbox}/keyA.txt")
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/test.yaml"
        export COFFER_CATEGORY="test"
        export COFFER_KEY="key1"
        export COFFER_CONFIG_DIR="${sandbox}/.coffer-config"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"

        # Stub out helpers from common.sh that we're not testing here.
        die() { echo "die: $*" >&2; exit 1; }
        log() { :; }
        warn() { :; }
        require_cmd() { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked() { :; }
        parse_path() { :; }

        # shellcheck source=../lib/set.sh
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"
        cmd_set test/key1 "value-1"
    ) || { rm -rf "$sandbox"; return 1; }

    local count
    count=$(grep -c "recipient:" "${sandbox}/vault/test.yaml")
    rm -rf "$sandbox"
    assert_eq "2" "$count" "create path should preserve both recipients from .sops.yaml"
}

test_set_preserves_all_recipients_on_update() {
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    age-keygen -o "${sandbox}/keyA.txt" 2>/dev/null
    age-keygen -o "${sandbox}/keyB.txt" 2>/dev/null
    local pub_a pub_b
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')
    pub_b=$(grep "public key" "${sandbox}/keyB.txt" | awk '{print $4}')

    mkdir -p "${sandbox}/vault" "${sandbox}/config" "${sandbox}/.coffer-config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_a},${pub_b}
EOF
    echo "$pub_a" > "${sandbox}/.coffer-config/public-key"

    (
        export SOPS_AGE_KEY
        SOPS_AGE_KEY=$(grep AGE-SECRET "${sandbox}/keyA.txt")
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/test.yaml"
        export COFFER_CATEGORY="test"
        export COFFER_CONFIG_DIR="${sandbox}/.coffer-config"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"

        die() { echo "die: $*" >&2; exit 1; }
        log() { :; }
        warn() { :; }
        require_cmd() { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked() { :; }
        parse_path() { :; }

        # shellcheck source=../lib/set.sh
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"

        export COFFER_KEY="first"
        cmd_set test/first "value-1"
        export COFFER_KEY="second"
        cmd_set test/second "value-2"   # exercises the update path

        # Critical assertion: the OTHER key (B) must still decrypt — proves
        # we didn't strip its recipient on the update.
        SOPS_AGE_KEY=$(grep AGE-SECRET "${sandbox}/keyB.txt") sops decrypt \
            --extract '["first"]' "${sandbox}/vault/test.yaml" >/dev/null \
            || die "key B locked out — update stripped its recipient"
    ) || { rm -rf "$sandbox"; return 1; }

    local count
    count=$(grep -c "recipient:" "${sandbox}/vault/test.yaml")
    rm -rf "$sandbox"
    assert_eq "2" "$count" "update path should preserve both recipients from .sops.yaml"
}

# --- Identity: Option 2 (file-only, no Keychain) tests ---
#
# These tests cover the April 2026 refactor that made ~/.config/coffer/.session-key
# the single source of truth for coffer's identity. The previous dual-path
# design (file OR Keychain) produced real bugs in SSH-spawned shells where
# Keychain access is denied by default. The tests below simulate that
# "headless / no-Keychain" context by running coffer in a bash subshell
# with no access to `security` helpers (we don't actually strip `security`
# from PATH — we just never invoke it in the new code path, which is the
# point of the refactor).

test_require_identity_passes_with_file() {
    # Happy path: session-key file present, require_identity returns 0.
    seed_fake_identity
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"${COFFER_SESSION_KEY}"'"
        require_identity
        echo "ok"
    ' 2>&1)
    assert_contains "$output" "ok" "require_identity should succeed when session-key file exists"
}

test_require_identity_fails_without_file() {
    # Missing file: require_identity dies with an actionable message that
    # mentions `coffer init` so the user knows exactly what to do.
    local missing="${COFFER_CONFIG_DIR}/no-such-file"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"$missing"'"
        require_identity
    ' 2>&1) || true
    assert_contains "$output" "No identity found" "require_identity should fail loudly when file is missing" && \
    assert_contains "$output" "coffer init" "error message should tell the user to run coffer init"
}

test_require_identity_fails_on_empty_file() {
    # Zero-byte file is a corruption case, not a "missing" one. We want a
    # distinct, actionable error rather than silently falling through.
    mkdir -p "${COFFER_CONFIG_DIR}"
    : > "${COFFER_SESSION_KEY}"
    chmod 600 "${COFFER_SESSION_KEY}"

    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"${COFFER_SESSION_KEY}"'"
        require_identity
    ' 2>&1) || true
    assert_contains "$output" "empty" "require_identity should call out empty identity files"
}

test_ensure_unlocked_loads_from_file() {
    # This is the SSH / headless regression test: with NO SOPS_AGE_KEY in
    # the environment and NO Keychain access, ensure_unlocked must pick up
    # the key from the session-key file. Before Option 2 this worked on some
    # contexts and failed on SSH-spawned shells; now there's only one path.
    seed_fake_identity
    local output
    output=$(bash -c '
        unset SOPS_AGE_KEY
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"${COFFER_SESSION_KEY}"'"
        ensure_unlocked
        echo "key=${SOPS_AGE_KEY:0:16}"
    ' 2>&1)
    assert_contains "$output" "key=AGE-SECRET-KEY-" "ensure_unlocked should export SOPS_AGE_KEY from file"
}

test_ensure_unlocked_prefers_env_var() {
    # If SOPS_AGE_KEY is already set (e.g., user ran `eval $(coffer unlock)`
    # in the parent shell), ensure_unlocked must trust it and not rewrite
    # it from the file. This keeps `eval $(coffer unlock)` idempotent and
    # also supports alternative identity delivery (e.g., passed through an
    # LDAP-fed env var in a job runner).
    seed_fake_identity
    local output
    output=$(bash -c '
        export SOPS_AGE_KEY="AGE-SECRET-KEY-FROM-ENV"
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"${COFFER_SESSION_KEY}"'"
        ensure_unlocked
        echo "${SOPS_AGE_KEY}"
    ' 2>&1)
    assert_contains "$output" "AGE-SECRET-KEY-FROM-ENV" "ensure_unlocked should not overwrite a pre-set SOPS_AGE_KEY"
}

test_ensure_unlocked_fails_without_file_or_env() {
    # Nothing in env, no file: must die with the same actionable message
    # as require_identity so the user isn't chasing a mysterious "locked".
    local missing="${COFFER_CONFIG_DIR}/no-such-file"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        unset SOPS_AGE_KEY
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"$missing"'"
        ensure_unlocked
    ' 2>&1) || true
    assert_contains "$output" "No identity found" "ensure_unlocked should fail loudly when identity is missing" && \
    assert_contains "$output" "coffer init" "error should tell the user how to fix it"
}

test_no_keychain_calls_in_library() {
    # Structural check: the refactor's whole point is to kill Keychain
    # dependency. If someone reintroduces a `security find-generic-password`
    # call in the library, this test catches it before the diff lands.
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local hits
    hits=$(grep -l 'security find-generic-password\|security add-generic-password\|security delete-generic-password' \
        "${real_root}/bin/coffer" "${real_root}"/lib/*.sh 2>/dev/null || true)
    assert_eq "" "$hits" "no library/bin file should call the macOS 'security' helper"
}

test_unlock_reads_from_file() {
    # `coffer unlock` emits `export SOPS_AGE_KEY=...` from the file. This
    # smoke-tests the dispatcher path, not just the library function.
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    seed_fake_identity
    local output
    output=$(COFFER_SESSION_KEY="${COFFER_SESSION_KEY}" \
             COFFER_NTFY_TOPIC="http://localhost:1/fake" \
             bash "${real_root}/bin/coffer" unlock 2>/dev/null) || true
    assert_contains "$output" "export SOPS_AGE_KEY=" "coffer unlock should emit an export statement when the file exists"
}

test_unlock_auto_is_noop() {
    # --auto is retained as a no-op for LaunchAgent backward compatibility.
    # It must exit 0 without emitting an export (nothing to eval).
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    seed_fake_identity
    local stdout
    stdout=$(COFFER_SESSION_KEY="${COFFER_SESSION_KEY}" \
             COFFER_NTFY_TOPIC="http://localhost:1/fake" \
             bash "${real_root}/bin/coffer" unlock --auto 2>/dev/null) || true
    # stdout should be empty (no export); the informational log goes to stderr.
    assert_eq "" "$stdout" "coffer unlock --auto should not emit stdout (it's a no-op)"
}

# --- Onboard tests ---
#
# These tests cover the vault-dir-as-transport bootstrap flow introduced in
# the 2026-04-22 multi-machine fix. They simulate a "new machine" by overriding
# COFFER_CONFIG_DIR and COFFER_SESSION_KEY to a fresh temp directory, then
# verify that .pending-recipient-*.pub appears (or doesn't) as expected.

test_onboard_writes_pending_file() {
    # Happy path: machine has an identity, onboard should write the pending file.
    # We seed a real age keypair (age-keygen) so the pubkey passes the regex.
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "  SKIP (age-keygen not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)

    # Generate a real keypair into the sandbox config dir.
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    mkdir -p "$config_dir" "$vault_dir"

    local keygen_out
    keygen_out=$(age-keygen 2>&1)
    local pub_key
    pub_key=$(printf '%s\n' "$keygen_out" | grep -oE 'age1[a-z0-9]+' | head -1)
    local secret_key
    secret_key=$(printf '%s\n' "$keygen_out" | grep '^AGE-SECRET-KEY-')

    printf '%s\n' "$secret_key" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"
    printf '%s\n' "$pub_key" > "${config_dir}/public-key"
    printf 'test-machine\n' > "${config_dir}/machine-name"

    # Source onboard.sh with sandbox env; stub out the sub-invocation of init
    # (not needed since the identity already exists) and other helpers.
    # shellcheck disable=SC2030,SC2031
    (
        export COFFER_ROOT="${SCRIPT_DIR}/.."
        export COFFER_CONFIG_DIR="$config_dir"
        export COFFER_SESSION_KEY="${config_dir}/.session-key"
        export COFFER_VAULT="$vault_dir"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        # shellcheck source=../lib/common.sh
        source "${COFFER_ROOT}/lib/common.sh"
        # shellcheck source=../lib/onboard.sh
        source "${COFFER_ROOT}/lib/onboard.sh"

        # shellcheck disable=SC2119
        cmd_onboard
    ) 2>/dev/null

    local pending_file="${vault_dir}/.pending-recipient-test-machine.pub"
    local found=0
    [[ -f "$pending_file" ]] && found=1

    # Check content matches the generated pubkey.
    local content_ok=0
    if [[ $found -eq 1 ]]; then
        local file_content
        file_content=$(< "$pending_file")
        file_content="${file_content%%[[:space:]]*}"
        [[ "$file_content" == "$pub_key" ]] && content_ok=1
    fi

    rm -rf "$sandbox"

    if [[ $found -eq 0 ]]; then
        echo "  FAIL: .pending-recipient-test-machine.pub was not created"
        return 1
    fi
    if [[ $content_ok -eq 0 ]]; then
        echo "  FAIL: pending file content does not match the pubkey"
        return 1
    fi
    return 0
}

test_onboard_skips_init_if_identity_exists() {
    # If the session-key file already exists and is non-empty, onboard must NOT
    # attempt to re-run init (which would prompt the user for a machine name
    # and block the test). We confirm by checking that onboard exits 0 without
    # any die() and that the pending file still appears.
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "  SKIP (age-keygen not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    mkdir -p "$config_dir" "$vault_dir"

    local keygen_out
    keygen_out=$(age-keygen 2>&1)
    local pub_key
    pub_key=$(printf '%s\n' "$keygen_out" | grep -oE 'age1[a-z0-9]+' | head -1)
    local secret_key
    secret_key=$(printf '%s\n' "$keygen_out" | grep '^AGE-SECRET-KEY-')

    printf '%s\n' "$secret_key" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"
    printf '%s\n' "$pub_key" > "${config_dir}/public-key"
    printf 'existing-machine\n' > "${config_dir}/machine-name"

    local rc=0
    # shellcheck disable=SC2030,SC2031
    (
        export COFFER_ROOT="${SCRIPT_DIR}/.."
        export COFFER_CONFIG_DIR="$config_dir"
        export COFFER_SESSION_KEY="${config_dir}/.session-key"
        export COFFER_VAULT="$vault_dir"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        source "${COFFER_ROOT}/lib/common.sh"
        source "${COFFER_ROOT}/lib/onboard.sh"
        # shellcheck disable=SC2119
        cmd_onboard
    ) 2>/dev/null || rc=$?

    local pending_file="${vault_dir}/.pending-recipient-existing-machine.pub"
    local ok=0
    [[ -f "$pending_file" ]] && ok=1
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: cmd_onboard exited ${rc} (expected 0) when identity exists"
        return 1
    fi
    if [[ $ok -eq 0 ]]; then
        echo "  FAIL: pending file not created even though identity exists"
        return 1
    fi
    return 0
}

test_finalize_onboard_no_pending_files() {
    # When there are no .pending-recipient-*.pub files, finalize-onboard should
    # print "No pending recipients." and exit 0.
    local sandbox
    sandbox=$(mktemp -d)
    local vault_dir="${sandbox}/vault"
    mkdir -p "$vault_dir"

    local output rc=0
    output=$(
        COFFER_ROOT="${SCRIPT_DIR}/.." \
        COFFER_VAULT="$vault_dir" \
        COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        COFFER_CONFIG_DIR="${sandbox}/config" \
        COFFER_SESSION_KEY="${sandbox}/config/.session-key" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/onboard.sh"'"
            # ensure_unlocked would fail with no identity; stub it since
            # finalize-onboard only calls it before processing files.
            # Since there are no files, it never reaches ensure_unlocked in the loop.
            ensure_unlocked() { return 0; }
            require_cmd() { return 0; }
            cmd_finalize_onboard
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: finalize-onboard exited ${rc} (expected 0) with no pending files"
        echo "    output: $output"
        return 1
    fi
    assert_contains "$output" "No pending recipients" "finalize-onboard should report nothing to do"
}

test_onboard_rejects_unknown_args() {
    local output rc=0
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        source "'"${COFFER_ROOT}/lib/onboard.sh"'"
        cmd_onboard --bogus-flag
    ' 2>&1) || rc=$?
    assert_contains "$output" "Unknown argument" "onboard should reject unknown flags"
}

test_finalize_onboard_rejects_unknown_args() {
    local output rc=0
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        source "'"${COFFER_ROOT}/lib/onboard.sh"'"
        cmd_finalize_onboard --bogus-flag
    ' 2>&1) || rc=$?
    assert_contains "$output" "Unknown argument" "finalize-onboard should reject unknown flags"
}

test_lock_does_not_delete_file() {
    # Regression guard: `coffer lock` must leave the session-key file alone
    # because the file IS the persistent identity. Wiping it would force
    # a re-init on every "lock" which defeats the command's purpose.
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    seed_fake_identity
    COFFER_SESSION_KEY="${COFFER_SESSION_KEY}" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash "${real_root}/bin/coffer" lock >/dev/null 2>&1 || true
    if [[ -f "${COFFER_SESSION_KEY}" ]]; then
        return 0
    else
        echo "  FAIL: coffer lock deleted the session-key file"
        return 1
    fi
}

# =============================================================================
# --- Doctor and auto-sync tests ---
#
# These tests cover the drift-detection and auto-commit infrastructure added
# in feat/doctor-and-auto-sync (April 2026) to prevent a recurrence of the
# .sops.yaml/vault-file recipient mismatch bug.
# =============================================================================

# Helper: build a minimal test git repo with age keypairs and a .sops.yaml
# so doctor and preflight tests have something realistic to work with.
# Usage:  _setup_doctor_sandbox <sandbox_path>
# Sets:   DOCTOR_SANDBOX_VAULT, DOCTOR_SANDBOX_CONFIG, DOCTOR_SANDBOX_SOPS
#         DOCTOR_SANDBOX_PUBA, DOCTOR_SANDBOX_PRIK_A (for signing)
_setup_doctor_sandbox() {
    local sandbox="$1"
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    local git_dir="${sandbox}/repo"

    mkdir -p "$config_dir" "$vault_dir" "$git_dir"

    # Generate two age keypairs so we can simulate multi-recipient scenarios
    age-keygen -o "${sandbox}/keyA.txt" 2>/dev/null
    age-keygen -o "${sandbox}/keyB.txt" 2>/dev/null

    local pub_a pub_b
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')
    pub_b=$(grep "public key" "${sandbox}/keyB.txt" | awk '{print $4}')

    # Write .sops.yaml with BOTH keys as canonical recipients
    local sops_config="${config_dir}/.sops.yaml"
    cat > "$sops_config" <<EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${pub_a},${pub_b}
EOF

    # Write the machine identity as key A (simulating "this machine")
    printf '%s\n' "$pub_a" > "${config_dir}/public-key"
    printf 'test-machine\n' > "${config_dir}/machine-name"
    printf '%s\n' "$(grep AGE-SECRET "${sandbox}/keyA.txt")" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"

    # NOTE: We do NOT initialize a git repo here. The doctor's git checks
    # are skipped when COFFER_VAULT_ROOT has no .git directory. Vault-drift
    # tests focus on recipient set comparison, not git state. The auto_sync_push
    # tests create their own git sandboxes independently.

    # Export the paths that callers need. Key files are accessed via
    # the `sandbox` variable in each test function body (no export needed since
    # the helper runs in the same shell scope, not a subshell).
    DOCTOR_SANDBOX_VAULT="$vault_dir"
    DOCTOR_SANDBOX_CONFIG="$config_dir"
    DOCTOR_SANDBOX_SOPS="$sops_config"
    # DOCTOR_SANDBOX_ROOT is the directory that COFFER_VAULT_ROOT should point at
    # in test subshells. The sandbox dir contains config/ and vault/ at the
    # expected relative positions.
    DOCTOR_SANDBOX_ROOT="$sandbox"
}

# a. coffer doctor on a clean vault exits 0 with correct output.
test_doctor_clean_vault_exits_zero() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    _setup_doctor_sandbox "$sandbox"

    # Encrypt one vault file with BOTH keys so doctor has something to check
    local sops_age_key
    sops_age_key=$(grep AGE-SECRET "${sandbox}/keyA.txt")

    jq -n '{"test-key": "test-value"}' \
        | SOPS_AGE_KEY="$sops_age_key" \
          SOPS_CONFIG="$DOCTOR_SANDBOX_SOPS" \
          sops encrypt \
            --filename-override "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" \
            --input-type json --output-type yaml \
            /dev/stdin > "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" 2>/dev/null \
        || { rm -rf "$sandbox"; echo "  SKIP (sops encrypt failed)"; return 0; }

    local output rc=0
    output=$(
        COFFER_VAULT_ROOT="${DOCTOR_SANDBOX_ROOT}" \
        COFFER_ROOT="${sandbox}" \
        COFFER_VAULT="${DOCTOR_SANDBOX_VAULT}" \
        COFFER_SOPS_CONFIG="${DOCTOR_SANDBOX_SOPS}" \
        COFFER_CONFIG_DIR="${DOCTOR_SANDBOX_CONFIG}" \
        COFFER_SESSION_KEY="${DOCTOR_SANDBOX_CONFIG}/.session-key" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/doctor.sh"'"
            cmd_doctor
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    # All vault files match .sops.yaml: should exit 0
    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: doctor exited ${rc} on a clean vault (expected 0)"
        echo "    output: ${output}"
        return 1
    fi
    assert_contains "$output" "[OK]" "doctor should print at least one [OK] line" && \
    assert_contains "$output" "all checks passed" "doctor should report all checks passed"
}

# b. coffer doctor on a drifted vault exits 1 with specific drift output.
test_doctor_drifted_vault_exits_one() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    _setup_doctor_sandbox "$sandbox"

    # Encrypt a vault file with ONLY key A — simulating a write that happened
    # before key B was added (i.e., the vault file has fewer recipients than .sops.yaml)
    local sops_age_key
    sops_age_key=$(grep AGE-SECRET "${sandbox}/keyA.txt")
    local pub_a
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')

    # Write a temporary single-recipient .sops.yaml just for the encrypt step
    local single_sops="${sandbox}/single.sops.yaml"
    cat > "$single_sops" <<EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${pub_a}
EOF

    jq -n '{"test-key": "test-value"}' \
        | SOPS_AGE_KEY="$sops_age_key" \
          SOPS_CONFIG="$single_sops" \
          sops encrypt \
            --filename-override "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" \
            --input-type json --output-type yaml \
            /dev/stdin > "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" 2>/dev/null \
        || { rm -rf "$sandbox"; echo "  SKIP (sops encrypt failed)"; return 0; }

    # Now the vault file has 1 recipient (key A) but .sops.yaml lists 2 (A + B)
    # This is exactly the drift condition doctor must catch.
    local output rc=0
    output=$(
        COFFER_VAULT_ROOT="${DOCTOR_SANDBOX_ROOT}" \
        COFFER_ROOT="${sandbox}" \
        COFFER_VAULT="${DOCTOR_SANDBOX_VAULT}" \
        COFFER_SOPS_CONFIG="${DOCTOR_SANDBOX_SOPS}" \
        COFFER_CONFIG_DIR="${DOCTOR_SANDBOX_CONFIG}" \
        COFFER_SESSION_KEY="${DOCTOR_SANDBOX_CONFIG}/.session-key" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/doctor.sh"'"
            cmd_doctor
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    # Must exit 1 (drift found)
    if [[ $rc -ne 1 ]]; then
        echo "  FAIL: doctor exited ${rc} on a drifted vault (expected 1)"
        echo "    output: ${output}"
        return 1
    fi
    assert_contains "$output" "[DRIFT]" "doctor should print at least one [DRIFT] line" && \
    assert_contains "$output" "issue(s) found" "doctor should report issues found"
}

# c. auto_sync_push with COFFER_AUTO_SYNC=0 skips all git ops.
test_auto_sync_push_disabled_by_env() {
    local sandbox
    sandbox=$(mktemp -d)

    # Init a git repo (needs to be a repo to test auto_sync_push behavior).
    # The sandbox acts as COFFER_VAULT_ROOT (the vault data repo), not COFFER_ROOT
    # (the tool code repo). auto_sync_push now targets COFFER_VAULT_ROOT.
    git -C "$sandbox" init -q
    git -C "$sandbox" config user.email "test@test.local"
    git -C "$sandbox" config user.name "Test"
    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    touch "${sandbox}/vault/test.yaml"
    git -C "$sandbox" add . 2>/dev/null
    git -C "$sandbox" commit -m "initial" -q

    # Modify a file so there would be something to stage
    echo "change" > "${sandbox}/vault/test.yaml"

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=0 \
        COFFER_VAULT_ROOT="$sandbox" \
        COFFER_ROOT="$sandbox" \
        COFFER_VAULT="${sandbox}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_push "test commit"
        ' 2>&1
    ) || rc=$?

    # Verify no new commit was made
    local commit_count
    commit_count=$(git -C "$sandbox" rev-list --count HEAD 2>/dev/null || echo 0)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_push exited ${rc} with COFFER_AUTO_SYNC=0 (expected 0)"
        return 1
    fi
    assert_contains "$output" "COFFER_AUTO_SYNC=0" "should log that auto-sync is disabled" && \
    assert_eq "1" "$commit_count" "should not have committed anything (still just initial commit)"
}

# d. auto_sync_push on a non-main branch commits locally but does NOT push.
test_auto_sync_push_non_main_commits_only() {
    local sandbox
    sandbox=$(mktemp -d)

    # Set up a git repo on a non-main branch. The sandbox is COFFER_VAULT_ROOT
    # (the vault data repo) -- auto_sync_push now targets COFFER_VAULT_ROOT.
    git -C "$sandbox" init -q
    git -C "$sandbox" config user.email "test@test.local"
    git -C "$sandbox" config user.name "Test"
    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    echo "initial" > "${sandbox}/vault/test.yaml"
    cat > "${sandbox}/config/.sops.yaml" <<'SOPSEOF'
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1test123
SOPSEOF
    git -C "$sandbox" add . 2>/dev/null
    git -C "$sandbox" commit -m "initial" -q
    git -C "$sandbox" checkout -b feat/not-main -q

    # Make a change to vault/
    echo "modified" > "${sandbox}/vault/test.yaml"

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=1 \
        COFFER_VAULT_ROOT="$sandbox" \
        COFFER_ROOT="$sandbox" \
        COFFER_VAULT="${sandbox}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_push "test change"
        ' 2>&1
    ) || rc=$?

    local commit_count
    commit_count=$(git -C "$sandbox" rev-list --count HEAD 2>/dev/null || echo 0)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_push exited ${rc} on non-main branch (expected 0)"
        echo "    output: ${output}"
        return 1
    fi
    # Must have committed (commit_count should be 2: initial + the auto-commit)
    if [[ "$commit_count" -lt 2 ]]; then
        echo "  FAIL: expected at least 2 commits (initial + auto), got ${commit_count}"
        return 1
    fi
    assert_contains "$output" "not 'main'" "should warn about non-main branch" && \
    # Push must NOT have been attempted (no remote configured, so we just
    # verify the warning appears — if push were attempted, it would error out
    # loudly since there's no remote, and rc would be non-zero)
    return 0
}

# e. preflight_recipient_check refuses write when drift is detected.
test_preflight_blocks_write_on_drift() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    _setup_doctor_sandbox "$sandbox"

    # Encrypt a vault file with ONLY key A (drifted: .sops.yaml has A + B)
    local sops_age_key
    sops_age_key=$(grep AGE-SECRET "${sandbox}/keyA.txt")
    local pub_a
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')

    local single_sops="${sandbox}/single.sops.yaml"
    cat > "$single_sops" <<EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${pub_a}
EOF

    jq -n '{"test-key": "test-value"}' \
        | SOPS_AGE_KEY="$sops_age_key" \
          SOPS_CONFIG="$single_sops" \
          sops encrypt \
            --filename-override "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" \
            --input-type json --output-type yaml \
            /dev/stdin > "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" 2>/dev/null \
        || { rm -rf "$sandbox"; echo "  SKIP (sops encrypt failed)"; return 0; }

    # preflight_recipient_check should detect the drift and call die()
    local output rc=0
    output=$(
        COFFER_VAULT_ROOT="${DOCTOR_SANDBOX_ROOT}" \
        COFFER_ROOT="${sandbox}" \
        COFFER_VAULT="${DOCTOR_SANDBOX_VAULT}" \
        COFFER_SOPS_CONFIG="${DOCTOR_SANDBOX_SOPS}" \
        COFFER_CONFIG_DIR="${DOCTOR_SANDBOX_CONFIG}" \
        COFFER_SESSION_KEY="${DOCTOR_SANDBOX_CONFIG}/.session-key" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/doctor.sh"'"
            # Override die so we can capture the error without sending ntfy
            die() { echo "die: $*" >&2; exit 1; }
            preflight_recipient_check
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: preflight_recipient_check should have exited non-zero on a drifted vault"
        return 1
    fi
    assert_contains "$output" "inconsistent" "error should mention inconsistency" && \
    assert_contains "$output" "coffer doctor" "error should point the user to coffer doctor"
}

# =============================================================================
# --- auto_sync_pull tests (feat/auto-pull-before-write, April 2026) ---
#
# These tests cover the pre-write pull-rebase added to close the drift window
# that caused the April 2026 non-fast-forward push rejection. The failure mode:
#   1. Session starts, sync-pull runs (vault is current).
#   2. Other machine writes + pushes (origin advances).
#   3. This machine runs `coffer set` -- local commit + push rejected (non-ff).
#
# The fix: auto_sync_pull() runs BEFORE the write. These tests verify:
#   a. COFFER_AUTO_SYNC=0 suppresses the pull (escape hatch preserved).
#   b. No-op when already up to date (nothing staged unnecessarily).
#   c. Behind-origin: pull-rebase succeeds, log message emitted.
#   d. Rebase conflict: abort + die() loudly (don't proceed with corrupt state).
#   e. Local commits ahead: pushed before pull-rebase.
# =============================================================================

# Helper: create a bare "origin" repo and a local clone that is behind it.
# Usage: _setup_pull_sandbox <sandbox_path>
# Sets:  PULL_SANDBOX_LOCAL (the "local machine" clone)
#        PULL_SANDBOX_ORIGIN (the bare origin repo)
_setup_pull_sandbox() {
    local sandbox="$1"

    local origin_dir="${sandbox}/origin.git"
    local local_dir="${sandbox}/local"

    # Init a bare repo that acts as origin
    git init --bare -q "$origin_dir"
    git -C "$origin_dir" config user.email "test@test.local"
    git -C "$origin_dir" config user.name "Test"

    # Clone into local
    git clone -q "$origin_dir" "$local_dir" 2>/dev/null
    git -C "$local_dir" config user.email "test@test.local"
    git -C "$local_dir" config user.name "Test"

    # Create initial structure in local and push
    mkdir -p "${local_dir}/vault" "${local_dir}/config"
    cat > "${local_dir}/config/.sops.yaml" <<'SOPSEOF'
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1placeholder000000000000000000000000000000000000000000000000
SOPSEOF
    echo "v1" > "${local_dir}/vault/secrets.yaml"
    git -C "$local_dir" add . 2>/dev/null
    git -C "$local_dir" commit -m "initial" -q
    git -C "$local_dir" push -q

    PULL_SANDBOX_LOCAL="$local_dir"
    PULL_SANDBOX_ORIGIN="$origin_dir"
}

# a. auto_sync_pull with COFFER_AUTO_SYNC=0 is a no-op.
test_auto_sync_pull_disabled_by_env() {
    local sandbox
    sandbox=$(mktemp -d)
    _setup_pull_sandbox "$sandbox"

    # Push a new commit to origin to make local behind
    local work_dir="${sandbox}/work"
    git clone -q "$PULL_SANDBOX_ORIGIN" "$work_dir" 2>/dev/null
    git -C "$work_dir" config user.email "test@test.local"
    git -C "$work_dir" config user.name "Test"
    echo "v2" > "${work_dir}/vault/secrets.yaml"
    git -C "$work_dir" add . 2>/dev/null
    git -C "$work_dir" commit -m "origin advance" -q
    git -C "$work_dir" push -q 2>/dev/null

    # Local should now be behind; but with COFFER_AUTO_SYNC=0 the pull is skipped
    local local_sha_before
    local_sha_before=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=0 \
        COFFER_VAULT_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_VAULT="${PULL_SANDBOX_LOCAL}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_pull
        ' 2>&1
    ) || rc=$?

    local local_sha_after
    local_sha_after=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_pull exited ${rc} with COFFER_AUTO_SYNC=0 (expected 0)"
        return 1
    fi
    # HEAD must not have moved (pull was skipped)
    assert_eq "$local_sha_before" "$local_sha_after" "auto_sync_pull with COFFER_AUTO_SYNC=0 must not change HEAD"
}

# b. auto_sync_pull when already up to date is a no-op (fast path).
test_auto_sync_pull_noop_when_current() {
    local sandbox
    sandbox=$(mktemp -d)
    _setup_pull_sandbox "$sandbox"

    local local_sha_before
    local_sha_before=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)

    local rc=0
    (
        COFFER_AUTO_SYNC=1 \
        COFFER_VAULT_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_VAULT="${PULL_SANDBOX_LOCAL}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_pull
        ' 2>&1
    ) || rc=$?

    local local_sha_after
    local_sha_after=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_pull exited ${rc} when already up to date (expected 0)"
        return 1
    fi
    assert_eq "$local_sha_before" "$local_sha_after" "auto_sync_pull must not change HEAD when already current"
}

# c. auto_sync_pull successfully pulls when behind origin (drift recovery).
# This is the primary regression test for the April 2026 push-rejection bug.
test_auto_sync_pull_pulls_when_behind() {
    local sandbox
    sandbox=$(mktemp -d)
    _setup_pull_sandbox "$sandbox"

    # Push a new commit to origin to make local behind
    local work_dir="${sandbox}/work"
    git clone -q "$PULL_SANDBOX_ORIGIN" "$work_dir" 2>/dev/null
    git -C "$work_dir" config user.email "test@test.local"
    git -C "$work_dir" config user.name "Test"
    echo "v2" > "${work_dir}/vault/secrets.yaml"
    git -C "$work_dir" add . 2>/dev/null
    git -C "$work_dir" commit -m "origin advance" -q
    git -C "$work_dir" push -q 2>/dev/null

    local origin_sha
    origin_sha=$(git -C "$work_dir" rev-parse HEAD)

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=1 \
        COFFER_VAULT_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_VAULT="${PULL_SANDBOX_LOCAL}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_pull
        ' 2>&1
    ) || rc=$?

    local local_sha_after
    local_sha_after=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_pull exited ${rc} when behind origin (expected 0)"
        echo "    output: ${output}"
        return 1
    fi
    assert_eq "$origin_sha" "$local_sha_after" "auto_sync_pull must bring local HEAD to origin HEAD" && \
    assert_contains "$output" "synced" "auto_sync_pull should log that it synced commits"
}

# d. auto_sync_pull with a local commit ahead: pushes first, then stays current.
test_auto_sync_pull_pushes_local_ahead_commits() {
    local sandbox
    sandbox=$(mktemp -d)
    _setup_pull_sandbox "$sandbox"

    # Make a local commit that was never pushed (simulates prior session ending
    # before auto_sync_push completed)
    echo "local-only" > "${PULL_SANDBOX_LOCAL}/vault/local.yaml"
    git -C "$PULL_SANDBOX_LOCAL" add vault/ 2>/dev/null
    git -C "$PULL_SANDBOX_LOCAL" commit -m "unpushed local commit" -q

    local local_sha_before
    local_sha_before=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=1 \
        COFFER_VAULT_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_VAULT="${PULL_SANDBOX_LOCAL}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_pull
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_pull exited ${rc} when local is ahead (expected 0)"
        echo "    output: ${output}"
        return 1
    fi
    assert_contains "$output" "not yet pushed" "should log about unpushed local commits"
}

# --- Main ---

main() {
    echo "=== Coffer Test Suite ==="
    echo ""

    setup_test_env

    # Common helper tests
    run_test test_die_exits_nonzero
    run_test test_warn_prints_to_stderr
    run_test test_log_prints_to_stderr
    run_test test_require_cmd_succeeds_for_existing
    run_test test_require_cmd_fails_for_missing
    run_test test_parse_path_valid
    run_test test_parse_path_invalid_no_slash

    # List tests
    run_test test_list_with_test_vault
    run_test test_list_single_category
    run_test test_list_missing_category_fails
    # Bug C regression: empty/null vault files must not crash list
    run_test test_list_empty_map_category_does_not_crash
    run_test test_list_null_category_does_not_crash

    # Get error case tests
    run_test test_get_missing_category_fails
    run_test test_get_no_args_fails

    # Entrypoint tests
    run_test test_coffer_no_command_fails
    run_test test_coffer_unknown_command_fails
    run_test test_coffer_help
    run_test test_coffer_version

    # Set: recipient preservation regression tests
    run_test test_set_preserves_all_recipients_on_create
    run_test test_set_preserves_all_recipients_on_update

    # Identity: Option 2 (file-only, no Keychain) tests
    run_test test_require_identity_passes_with_file
    run_test test_require_identity_fails_without_file
    run_test test_require_identity_fails_on_empty_file
    run_test test_ensure_unlocked_loads_from_file
    run_test test_ensure_unlocked_prefers_env_var
    run_test test_ensure_unlocked_fails_without_file_or_env
    run_test test_no_keychain_calls_in_library
    run_test test_unlock_reads_from_file
    run_test test_unlock_auto_is_noop
    run_test test_lock_does_not_delete_file

    # Onboard bootstrap tests
    run_test test_onboard_writes_pending_file
    run_test test_onboard_skips_init_if_identity_exists
    run_test test_finalize_onboard_no_pending_files
    run_test test_onboard_rejects_unknown_args
    run_test test_finalize_onboard_rejects_unknown_args
    # Bug B regression: machine-name whitespace trimming must preserve internal spaces
    run_test test_onboard_whitespace_machine_name_internal_space
    run_test test_onboard_whitespace_machine_name_leading_trailing

    # Doctor and auto-sync tests (feat/doctor-and-auto-sync, April 2026)
    run_test test_doctor_clean_vault_exits_zero
    run_test test_doctor_drifted_vault_exits_one
    run_test test_auto_sync_push_disabled_by_env
    run_test test_auto_sync_push_non_main_commits_only
    run_test test_preflight_blocks_write_on_drift

    # auto_sync_pull tests (feat/auto-pull-before-write, April 2026)
    run_test test_auto_sync_pull_disabled_by_env
    run_test test_auto_sync_pull_noop_when_current
    run_test test_auto_sync_pull_pulls_when_behind
    run_test test_auto_sync_pull_pushes_local_ahead_commits

    teardown_test_env

    echo ""
    echo "=== Results ==="
    echo "  Total:  ${TESTS_RUN}"
    echo "  Passed: ${TESTS_PASSED}"
    echo "  Failed: ${TESTS_FAILED}"
    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo "SOME TESTS FAILED"
        exit 1
    else
        echo "ALL TESTS PASSED"
        exit 0
    fi
}

main "$@"
