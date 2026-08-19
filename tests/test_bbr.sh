#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/bbr.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

passed=0
failed=0

pass() {
    printf 'ok - %s\n' "$1"
    passed=$((passed + 1))
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failed=$((failed + 1))
}

run_test() {
    local name=$1
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

make_fake_sysctl() {
    local path=$1
    printf '%s\n' '#!/usr/bin/env bash' \
        'set -u' \
        'state=${FAKE_SYSCTL_STATE:?}' \
        'trim() {' \
        '    local value=$1' \
        '    value="${value#"${value%%[![:space:]]*}"}"' \
        '    value="${value%"${value##*[![:space:]]}"}"' \
        '    printf "%s" "$value"' \
        '}' \
        'set_value() {' \
        '    local key=$1 value=$2 line current tmp' \
        '    tmp="${state}.tmp.$$"' \
        '    : > "$tmp"' \
        '    if [[ -f "$state" ]]; then' \
        '        while IFS= read -r line; do' \
        '            current=${line%%=*}' \
        '            [[ "$current" == "$key" ]] && continue' \
        '            printf "%s\n" "$line" >> "$tmp"' \
        '        done < "$state"' \
        '    fi' \
        '    printf "%s=%s\n" "$key" "$value" >> "$tmp"' \
        '    mv -f -- "$tmp" "$state"' \
        '}' \
        'if [[ "${1:-}" == "--system" ]]; then' \
        '    [[ "${FAKE_SYSTEM_FAIL:-0}" != 1 ]] || exit 1' \
        '    : > "$state"' \
        '    for file in ${FAKE_SYSCTL_FILES:-}; do' \
        '        [[ -f "$file" ]] || continue' \
        '        while IFS= read -r line; do' \
        '            [[ "$line" =~ ^[[:space:]]*net\. ]] || continue' \
        '            key=$(trim "${line%%=*}")' \
        '            value=${line#*=}' \
        '            value=$(trim "${value%%#*}")' \
        '            printf "%s=%s\n" "$key" "$value" >> "$state"' \
        '        done < "$file"' \
        '    done' \
        '    exit 0' \
        'fi' \
        'case "${1:-}" in' \
        '    -w)' \
        '        assignment=${2:-}' \
        '        key=${assignment%%=*}' \
        '        value=${assignment#*=}' \
        '        [[ "${FAKE_WRITE_FAIL_KEY:-}" != "$key" ]] || exit 1' \
        '        set_value "$key" "$value"' \
        '        ;;' \
        '    -n)' \
        '        key=${2:-}' \
        '        if [[ "${FAKE_MISMATCH_KEY:-}" == "$key" ]]; then' \
        '            printf "%s\n" wrong' \
        '            exit 0' \
        '        fi' \
        '        awk -F= -v key="$key" '\''$1 == key { print substr($0, index($0, "=") + 1); found=1; exit } END { if (!found) exit 1 }'\'' "$state"' \
        '        ;;' \
        '    *) exit 1 ;;' \
        'esac' > "$path"
    chmod +x "$path"
}

make_fake_os_release() {
    printf '%s\n' 'ID=debian' 'VERSION_ID="12"' > "$1"
}

make_fake_meminfo() {
    printf '%s\n' 'MemTotal:       8388608 kB' > "$1"
}

test_source_does_not_run_menu() {
    local output
    output=$(printf '0\n' | bash -c 'source "$1"; printf __LOADED__' _ "$SCRIPT")
    [[ "$output" == '__LOADED__' ]]
}

test_parsers_accept_bare_numbers_only() {
    bash -c '
        source "$1"
        [[ "$(parse_bw 1000)" == 1000000000 ]] || { echo "parse_bw 1000 -> $(parse_bw 1000)" >&2; exit 1; }
        [[ "$(parse_bw 100)" == 100000000 ]] || { echo "parse_bw 100 -> $(parse_bw 100)" >&2; exit 1; }
        [[ "$(parse_bw 0.5)" == 500000 ]] || { echo "parse_bw 0.5 -> $(parse_bw 0.5)" >&2; exit 1; }
        [[ "$(parse_rtt 20)" == 20.000 ]] || { echo "parse_rtt 20 -> $(parse_rtt 20)" >&2; exit 1; }
        [[ "$(parse_rtt 0.5)" == 0.500 ]] || { echo "parse_rtt 0.5 -> $(parse_rtt 0.5)" >&2; exit 1; }
    ' _ "$SCRIPT"
}

test_parsers_reject_suffixed_values() {
    bash -c '
        source "$1"
        ! parse_bw 125MB/s || exit 1
        ! parse_bw 500M || exit 1
        ! parse_bw 1G || exit 1
        ! parse_bw 1Gbps || exit 1
        ! parse_rtt 30ms || exit 1
        ! parse_rtt 0.5s || exit 1
    ' _ "$SCRIPT"
}

test_parsers_reject_invalid_and_overflowing_values() {
    bash -c '
        source "$1"
        ! parse_bw 0
        ! parse_bw -1G
        ! parse_bw 999999999999999999999999999G
        ! parse_rtt 0
        ! parse_rtt -1ms
        ! parse_rtt 999999999999999999999999999s
    ' _ "$SCRIPT"
}

test_missing_dependency_is_reported() {
    PATH="$TEST_TMP/empty-path" /bin/bash -c '
        source "$1"
        ! require_commands command_that_does_not_exist
    ' _ "$SCRIPT"
}

test_atomic_writer_rejects_missing_target_directory() {
    bash -c '
        source "$1"
        ! write_config_atomic "$2/missing/out.conf" <<< "net.test = 1"
        [[ ! -e "$2/missing/out.conf" ]]
    ' _ "$SCRIPT" "$TEST_TMP"
}

test_atomic_writer_replaces_target_with_expected_mode() {
    local target="$TEST_TMP/atomic/out.conf"
    mkdir -p "${target%/*}"
    bash -c '
        source "$1"
        write_config_atomic "$2" <<< "net.test = 1"
    ' _ "$SCRIPT" "$target" &&
        [[ "$(<"$target")" == 'net.test = 1' ]] &&
        [[ "$(stat -c '%a' "$target")" == 644 ]]
}

test_atomic_writer_preserves_existing_target_when_move_fails() {
    local fakebin="$TEST_TMP/fakebin-mv" target="$TEST_TMP/move/out.conf"
    mkdir -p "$fakebin" "${target%/*}"
    printf '%s\n' 'old value' > "$target"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fakebin/mv"
    chmod +x "$fakebin/mv"
    PATH="$fakebin:$PATH" bash -c '
        source "$1"
        ! write_config_atomic "$2" <<< "new value"
    ' _ "$SCRIPT" "$target" &&
        [[ "$(<"$target")" == 'old value' ]]
}

test_deletion_reports_remove_failure() {
    local fakebin="$TEST_TMP/fakebin-rm" candidate
    mkdir -p "$fakebin"
    candidate="$TEST_TMP/sysctl.d/10-network.conf"
    mkdir -p "${candidate%/*}"
    printf '%s\n' 'net.test = 1' > "$candidate"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fakebin/rm"
    chmod +x "$fakebin/rm"
    printf 'y\n' |
        SYSCTL_DIRS="$TEST_TMP/sysctl.d" SYSCTL_CONF="$TEST_TMP/sysctl.conf" \
        PATH="$fakebin:$PATH" bash -c 'source "$1"; ! delete_net_files' _ "$SCRIPT"
}

test_verification_checks_every_requested_key() {
    local fakebin="$TEST_TMP/fakebin-sysctl"
    mkdir -p "$fakebin"
    printf '%s\n' '#!/usr/bin/env bash' \
        'if [[ "$1" == "-n" && "$2" == "net.good" ]]; then printf "1\\n"; exit 0; fi' \
        'if [[ "$1" == "-n" && "$2" == "net.bad" ]]; then printf "wrong\\n"; exit 0; fi' \
        'exit 1' > "$fakebin/sysctl"
    chmod +x "$fakebin/sysctl"
    PATH="$fakebin:$PATH" bash -c '
        source "$1"
        ! verify_sysctl_values net.good 1 net.bad expected
    ' _ "$SCRIPT"
}

test_verification_normalizes_vector_values() {
    local fakebin="$TEST_TMP/fakebin-sysctl-vector"
    mkdir -p "$fakebin"
    printf '%s\n' '#!/usr/bin/env bash' \
        '[[ "$1" == "-n" && "$2" == "net.vector" ]] || exit 1' \
        'printf "  1   2  3 \\n"' > "$fakebin/sysctl"
    chmod +x "$fakebin/sysctl"
    PATH="$fakebin:$PATH" bash -c '
        source "$1"
        verify_sysctl_value net.vector "1 2 3"
    ' _ "$SCRIPT"
}

test_tune_tcp_verifies_every_written_value() {
    local fakebin="$TEST_TMP/fakebin-tune" conf state os_release meminfo
    fakebin="$fakebin/bin"
    conf="$TEST_TMP/tune/99-bbr-tune.conf"
    state="$TEST_TMP/tune/sysctl.state"
    os_release="$TEST_TMP/tune/os-release"
    meminfo="$TEST_TMP/tune/meminfo"
    mkdir -p "$fakebin" "${conf%/*}"
    make_fake_sysctl "$fakebin/sysctl"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/modprobe"
    chmod +x "$fakebin/modprobe"
    make_fake_os_release "$os_release"
    make_fake_meminfo "$meminfo"
    printf '1000\n20\ny\n' |
        PATH="$fakebin:$PATH" TUNE_CONF="$conf" OS_RELEASE_FILE="$os_release" \
        MEMINFO_FILE="$meminfo" FAKE_SYSCTL_STATE="$state" \
        FAKE_SYSCTL_FILES="$conf" bash -c 'source "$1"; tune_tcp' _ "$SCRIPT" \
        >/dev/null 2>&1 &&
        grep -q 'net.ipv4.tcp_notsent_lowat = 131072' "$conf"
}

test_tune_tcp_rejects_partial_verification() {
    local fakebin="$TEST_TMP/fakebin-tune-mismatch" conf state os_release meminfo
    fakebin="$fakebin/bin"
    conf="$TEST_TMP/tune-mismatch/99-bbr-tune.conf"
    state="$TEST_TMP/tune-mismatch/sysctl.state"
    os_release="$TEST_TMP/tune-mismatch/os-release"
    meminfo="$TEST_TMP/tune-mismatch/meminfo"
    mkdir -p "$fakebin" "${conf%/*}"
    make_fake_sysctl "$fakebin/sysctl"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/modprobe"
    chmod +x "$fakebin/modprobe"
    make_fake_os_release "$os_release"
    make_fake_meminfo "$meminfo"
    printf '1000\n20\ny\n' |
        PATH="$fakebin:$PATH" TUNE_CONF="$conf" OS_RELEASE_FILE="$os_release" \
        MEMINFO_FILE="$meminfo" FAKE_SYSCTL_STATE="$state" \
        FAKE_SYSCTL_FILES="$conf" FAKE_MISMATCH_KEY=net.ipv4.tcp_notsent_lowat \
        bash -c 'source "$1"; ! tune_tcp' _ "$SCRIPT" >/dev/null 2>&1
}

test_concurrency_verifies_every_written_value() {
    local fakebin="$TEST_TMP/fakebin-concurrency" conf state os_release
    fakebin="$fakebin/bin"
    conf="$TEST_TMP/concurrency/99-bbr-concurrency.conf"
    state="$TEST_TMP/concurrency/sysctl.state"
    os_release="$TEST_TMP/concurrency/os-release"
    mkdir -p "$fakebin" "${conf%/*}"
    make_fake_sysctl "$fakebin/sysctl"
    make_fake_os_release "$os_release"
    PATH="$fakebin:$PATH" CONC_CONF="$conf" OS_RELEASE_FILE="$os_release" \
        FAKE_SYSCTL_STATE="$state" FAKE_SYSCTL_FILES="$conf" \
        bash -c 'source "$1"; tune_concurrency' _ "$SCRIPT" >/dev/null 2>&1 &&
        grep -q 'net.ipv4.tcp_fin_timeout = 30' "$conf"
}

test_bbr_falls_back_when_fq_write_fails() {
    local fakebin="$TEST_TMP/fakebin-bbr" conf state os_release available
    fakebin="$fakebin/bin"
    conf="$TEST_TMP/bbr/99-bbr.conf"
    state="$TEST_TMP/bbr/sysctl.state"
    os_release="$TEST_TMP/bbr/os-release"
    available="$TEST_TMP/bbr/tcp_available"
    mkdir -p "$fakebin" "${conf%/*}"
    make_fake_sysctl "$fakebin/sysctl"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/modprobe"
    chmod +x "$fakebin/modprobe"
    make_fake_os_release "$os_release"
    printf '%s\n' 'cubic bbr' > "$available"
    PATH="$fakebin:$PATH" CONF_FILE="$conf" OS_RELEASE_FILE="$os_release" \
        TCP_AVAILABLE_FILE="$available" FAKE_SYSCTL_STATE="$state" \
        FAKE_SYSCTL_FILES="$conf" FAKE_WRITE_FAIL_KEY=net.core.default_qdisc \
        bash -c 'source "$1"; enable_bbr' _ "$SCRIPT" >/dev/null 2>&1 &&
        [[ "$(<"$conf")" == 'net.ipv4.tcp_congestion_control = bbr' ]]
}

test_menu_smoke_exits_on_zero() {
    printf '0\n' | TERM=xterm bash "$SCRIPT" >/dev/null 2>&1
}

run_test 'sourcing does not run menu' test_source_does_not_run_menu
run_test 'parsers accept bare numbers as Mbps and ms' test_parsers_accept_bare_numbers_only
run_test 'parsers reject suffixed values' test_parsers_reject_suffixed_values
run_test 'parsers reject invalid and overflowing values' test_parsers_reject_invalid_and_overflowing_values
run_test 'missing dependencies are reported' test_missing_dependency_is_reported
run_test 'atomic writer rejects missing target directory' test_atomic_writer_rejects_missing_target_directory
run_test 'atomic writer writes mode 0644' test_atomic_writer_replaces_target_with_expected_mode
run_test 'atomic writer preserves target on move failure' test_atomic_writer_preserves_existing_target_when_move_fails
run_test 'deletion reports remove failure' test_deletion_reports_remove_failure
run_test 'verification reports a mismatched key' test_verification_checks_every_requested_key
run_test 'verification normalizes vector values' test_verification_normalizes_vector_values
run_test 'TCP tuning verifies every written value' test_tune_tcp_verifies_every_written_value
run_test 'TCP tuning rejects partial verification' test_tune_tcp_rejects_partial_verification
run_test 'concurrency tuning verifies every written value' test_concurrency_verifies_every_written_value
run_test 'BBR falls back when fq cannot be written' test_bbr_falls_back_when_fq_write_fails
run_test 'menu exits on option zero' test_menu_smoke_exits_on_zero

printf '\n%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
