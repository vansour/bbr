# BBR Script Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the BBR management script fail-safe and fully verifiable while preserving its intentional no-backup and broad deletion behavior.

**Architecture:** Keep the project as a single Bash entrypoint, but move the interactive loop into `main` so functions can be sourced by tests. Add small helpers for atomic writes, sysctl application, normalized verification, dependency checks, and deletion result tracking. Use environment-overridable paths only for tests; production defaults remain unchanged.

**Tech Stack:** Bash, procps `sysctl`, standard POSIX utilities, dependency-free shell tests.

---

### Task 1: Add a sourceable test harness and failing regression tests

**Files:**
- Create: `tests/test_bbr.sh`
- Modify: `bbr.sh:14-433` only after the tests fail

- [x] **Step 1: Write the failing tests**

Create a test runner with `set -u`, temporary directories, assertion helpers, and tests for:

```bash
test_source_does_not_run_menu() {
    local output
    output=$(printf '0\n' | bash -c 'source "$1"; printf __LOADED__' _ "$SCRIPT")
    [[ "$output" == *__LOADED__* ]]
}

test_parsers_remain_compatible() {
    bash -c 'source "$1"; [[ "$(parse_bw 125MB/s)" == 1000000000 ]]; [[ "$(parse_rtt 0.5s)" == 500.000 ]]' _ "$SCRIPT"
}

test_atomic_writer_rejects_missing_target_directory() {
    bash -c 'source "$1"; ! write_config_atomic "$2/missing/out.conf" <<< "net.test = 1"' _ "$SCRIPT" "$TMPDIR"
}

test_deletion_reports_remove_failure() {
    local fakebin="$TMPDIR/fakebin" candidate
    mkdir -p "$fakebin"
    candidate="$TMPDIR/sysctl.d/10-network.conf"
    mkdir -p "${candidate%/*}"
    printf '%s\n' 'net.test = 1' > "$candidate"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fakebin/rm"
    chmod +x "$fakebin/rm"
    SYSCTL_DIRS="$TMPDIR/sysctl.d" SYSCTL_CONF="$TMPDIR/sysctl.conf" \
        PATH="$fakebin:$PATH" bash -c 'source "$1"; delete_net_files </dev/null' _ "$SCRIPT"
}

test_verification_checks_every_requested_key() {
    local fakebin="$TMPDIR/fakebin-sysctl"
    mkdir -p "$fakebin"
    printf '%s\n' '#!/usr/bin/env bash' \
        'if [[ "$1" == "-n" && "$2" == "net.good" ]]; then printf "1\\n"; exit 0; fi' \
        'if [[ "$1" == "-n" && "$2" == "net.bad" ]]; then printf "wrong\\n"; exit 0; fi' \
        'exit 1' > "$fakebin/sysctl"
    chmod +x "$fakebin/sysctl"
    PATH="$fakebin:$PATH" bash -c 'source "$1"; ! verify_sysctl_values net.good 1 net.bad expected' _ "$SCRIPT"
}
```

The test runner will define `SCRIPT` and `TMPDIR`, set `SYSCTL_DIRS` and `SYSCTL_CONF` only inside the child shells, and assert each test function's exit status.

- [x] **Step 2: Run the new test file and verify it fails for the intended reason**

Run:

```bash
bash tests/test_bbr.sh
```

Expected: failure because sourcing `bbr.sh` currently enters the menu, and `write_config_atomic` does not yet exist. Do not modify production code before observing this failure.

- [x] **Step 3: Add the direct-execution guard and test-only path overrides**

Wrap the current bottom menu loop in `main()`, then append:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
```

Define production defaults with `${VAR:-default}` for configuration paths and add `SYSCTL_CONF` for `/etc/sysctl.conf`, allowing tests to use temporary directories without changing production behavior.

- [x] **Step 4: Run the source and parser tests**

Run:

```bash
bash tests/test_bbr.sh
```

Expected: source and parser tests pass; the new helper-dependent tests remain red.

### Task 2: Implement atomic configuration writes and prerequisite checks

**Files:**
- Modify: `bbr.sh` near constants and helper functions
- Test: `tests/test_bbr.sh`

- [x] **Step 1: Add the minimal atomic writer**

Implement `write_config_atomic target` so it:

1. Creates a temporary file in the target directory with `mktemp`.
2. Copies stdin into it and checks the copy status.
3. Applies mode `0644`.
4. Replaces the target with `mv -f --` only after all previous steps succeed.
5. Removes the temporary file on every failure path and returns nonzero.

Replace the three direct heredoc writes with `write_config_atomic "$CONF_FILE" <<'EOF'` or the equivalent quoted/unquoted heredoc. Print the success message only after the helper returns zero.

- [x] **Step 2: Add command and environment checks**

Add `require_commands` for `awk`, `grep`, `sed`, `readlink`, `sysctl`, and `dpkg`, plus `modprobe` where BBR probing is used. Report the missing command and return nonzero. Add a readable `/etc/os-release` check before sourcing it.

- [x] **Step 3: Run atomic-write and prerequisite tests**

Run:

```bash
bash tests/test_bbr.sh
```

Expected: atomic-write and missing-command tests pass without creating a partial target file.

### Task 3: Add strict sysctl application and complete verification

**Files:**
- Modify: `bbr.sh` around sysctl helpers and `enable_bbr`, `tune_tcp`, `tune_concurrency`
- Test: `tests/test_bbr.sh`

- [x] **Step 1: Add normalized sysctl readers and verifiers**

Implement helpers with these interfaces:

```bash
normalize_sysctl_value() {
    awk '{$1=$1; print}'
}
verify_sysctl_value() {
    local key=$1 expected=$2 actual
    actual=$(sysctl -n "$key" 2>/dev/null) || return 1
    [[ "$(normalize_sysctl_value <<<"$actual")" == "$(normalize_sysctl_value <<<"$expected")" ]]
}
verify_sysctl_values() {
    while (( $# >= 2 )); do
        verify_sysctl_value "$1" "$2" || return 1
        shift 2
    done
}
apply_sysctl_system() {
    sysctl --system
}
```

`verify_sysctl_value` must compare normalized scalar/vector output, print the expected and actual values on mismatch, and return nonzero. `verify_sysctl_values` must stop with a failure if any pair is wrong. `apply_sysctl_system` must preserve and report command failure rather than silently discarding it.

- [x] **Step 2: Update BBR application and fallback**

Check the atomic write result, apply the system configuration, explicitly apply BBR, and verify `net.ipv4.tcp_congestion_control`. If fq application fails, atomically rewrite the BBR file with only the BBR key, report the downgrade, and verify BBR still works. Do not report a complete operation when the final required value is not active.

- [x] **Step 3: Update TCP and concurrency verification**

After applying each configuration, verify every generated value:

```text
TCP: net.core.rmem_max, net.core.wmem_max, net.ipv4.tcp_rmem,
     net.ipv4.tcp_wmem, net.ipv4.tcp_slow_start_after_idle,
     net.ipv4.tcp_notsent_lowat
Concurrency: net.core.somaxconn, net.ipv4.tcp_max_syn_backlog,
             net.core.netdev_max_backlog, net.ipv4.ip_local_port_range,
             net.ipv4.tcp_syncookies, net.ipv4.tcp_fin_timeout
```

Return nonzero on any mismatch and distinguish a persisted file from a fully applied runtime configuration.

- [x] **Step 4: Run failure and complete-verification tests**

Run:

```bash
bash tests/test_bbr.sh
```

Expected: fake `sysctl` failures and individual mismatches are detected; all-success fixtures pass.

### Task 4: Make deletion result reporting precise without changing its scope

**Files:**
- Modify: `bbr.sh:86-149`
- Test: `tests/test_bbr.sh`

- [x] **Step 1: Preserve discovery and improve preview wording**

Keep the existing directories, realpath deduplication, active-line matching, and confirmation prompt. Add a warning that matching files may contain unrelated network settings and that deletion is permanent by design. Do not add backup creation or narrow the target set.

- [x] **Step 2: Track every removal failure**

For each candidate, report success only when `rm -f --` succeeds. Set a failure flag for any failed removal, print an error for that path, and return nonzero after processing all candidates. Keep the existing package-file warning.

- [x] **Step 3: Run deletion tests**

Run:

```bash
bash tests/test_bbr.sh
```

Expected: successful removal returns zero; a fake failing `rm` returns nonzero and is visible to the caller.

### Task 5: Harden numeric boundaries and align documentation

**Files:**
- Modify: `bbr.sh:217-320`, `README.md:52-103`
- Test: `tests/test_bbr.sh`

- [x] **Step 1: Handle prompt EOF and numeric limits**

Check each `read` result and treat EOF as cancellation. Keep all documented valid formats. Reject bandwidth/RTT values that would make the BDP or buffer arithmetic non-finite, negative, or outside the representable range before Bash arithmetic. Preserve the 1MB/64MB buffer limits and make the low-memory ordering explicit so the documented memory cap is not accidentally violated.

- [x] **Step 2: Correct messages and README**

Document the default-buffer clamp of 256KB to 4MB, clarify that the example uses binary display units where applicable, describe `tcp_fin_timeout` as FIN-WAIT-2 behavior, and state that deletion can remove unrelated `net.*` settings. Describe `pfifo_fast` as the value selected by the script and note that existing interface queues may not change immediately.

- [x] **Step 3: Run parser and boundary tests**

Run:

```bash
bash tests/test_bbr.sh
```

Expected: documented valid inputs pass, zero/negative/unknown/overflow inputs fail, and the buffer calculation remains bounded.

### Task 6: Full verification and cleanup

**Files:**
- Modify: `tests/test_bbr.sh` only if test cleanup is required

- [x] **Step 1: Run the complete verification suite**

```bash
bash -n bbr.sh
shellcheck -x bbr.sh
bash tests/test_bbr.sh
git diff --check
printf '0\\n' | TERM=xterm bash bbr.sh
```

Expected: every command exits zero, the menu smoke test exits cleanly, and no test writes under `/etc` or changes live sysctl state.

- [x] **Step 2: Inspect the final diff and worktree**

```bash
git diff -- bbr.sh README.md tests/test_bbr.sh docs/superpowers/specs/2026-08-17-bbr-robustness-design.md docs/superpowers/plans/2026-08-17-bbr-robustness-plan.md
git status --short --branch
```

Confirm that no backup or restore path was introduced, only intended files changed, and all user-facing messages match the implementation.
