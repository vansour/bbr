#!/usr/bin/env bash
#=============================================================
# Debian / Ubuntu BBR 一键管理脚本
#
#  开启: 写入 99-bbr.conf（bbr + fq）
#  调优: 写入 99-bbr-tune.conf（按带宽×延迟计算的缓冲区参数）
#  并发: 写入 99-bbr-concurrency.conf（服务器大并发阈值参数）
#  删除: 删除所有包含网络参数的 sysctl 文件，恢复默认
#
#  三个配置互不冲突、可叠加生效；删除操作不做备份
#  用法: sudo bash bbr.sh
#=============================================================

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

CONF_FILE="${CONF_FILE:-/etc/sysctl.d/99-bbr.conf}"
TUNE_CONF="${TUNE_CONF:-/etc/sysctl.d/99-bbr-tune.conf}"
CONC_CONF="${CONC_CONF:-/etc/sysctl.d/99-bbr-concurrency.conf}"
SYSCTL_DIRS="${SYSCTL_DIRS:-/run/sysctl.d /etc/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d}"
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.conf}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
TCP_AVAILABLE_FILE="${TCP_AVAILABLE_FILE:-/proc/sys/net/ipv4/tcp_available_congestion_control}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"

ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${BLUE}[·]${NC} $*"; }

#-------------------------------------------------------------
# 通用可靠性 helpers
#-------------------------------------------------------------

require_commands() {
    local command_name missing=0
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            err "缺少依赖命令: $command_name"
            missing=1
        fi
    done
    return "$missing"
}

write_config_atomic() {
    if [[ $# -ne 1 ]]; then
        err "配置目标参数数量错误"
        return 1
    fi
    local target=$1 dir temp
    dir=${target%/*}
    [[ "$dir" == "$target" ]] && dir=.
    if [[ ! -d "$dir" ]]; then
        err "配置目录不存在，无法写入: $dir"
        return 1
    fi

    temp=$(mktemp "$dir/.bbr-config.XXXXXX") || {
        err "无法创建配置临时文件: $target"
        return 1
    }
    if ! cat > "$temp"; then
        err "写入配置临时文件失败: $target"
        rm -f -- "$temp" || true
        return 1
    fi
    if ! chmod 0644 -- "$temp"; then
        err "设置配置文件权限失败: $target"
        rm -f -- "$temp" || true
        return 1
    fi
    if ! mv -f -- "$temp" "$target"; then
        err "替换配置文件失败: $target"
        rm -f -- "$temp" || true
        return 1
    fi
    return 0
}

normalize_sysctl_value() {
    awk '{$1=$1; print}'
}

verify_sysctl_value() {
    if [[ $# -ne 2 ]]; then
        err "sysctl 校验参数数量错误"
        return 1
    fi
    local key=$1 expected=$2 actual expected_normalized actual_normalized
    if ! actual=$(sysctl -n "$key" 2>/dev/null); then
        err "无法读取 sysctl 参数: $key"
        return 1
    fi
    expected_normalized=$(normalize_sysctl_value <<<"$expected")
    actual_normalized=$(normalize_sysctl_value <<<"$actual")
    if [[ "$actual_normalized" != "$expected_normalized" ]]; then
        err "sysctl 校验失败: $key（期望: $expected_normalized；实际: $actual_normalized）"
        return 1
    fi
    return 0
}

verify_sysctl_values() {
    local status=0
    if (( $# % 2 != 0 )); then
        err "sysctl 校验参数必须成对提供"
        return 1
    fi
    while (( $# >= 2 )); do
        if ! verify_sysctl_value "$1" "$2"; then
            status=1
        fi
        shift 2
    done
    return "$status"
}

apply_sysctl_system() {
    sysctl --system
}

#-------------------------------------------------------------
# 前置检查
#-------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "需要 root 权限，请使用: sudo bash $0"
        return 1
    fi
    return 0
}

check_os() {
    require_commands dpkg || return 1
    if [[ ! -r "$OS_RELEASE_FILE" ]]; then
        err "无法读取系统信息文件: $OS_RELEASE_FILE"
        return 1
    fi
    # shellcheck disable=SC1090
    . "$OS_RELEASE_FILE" || {
        err "读取系统信息文件失败: $OS_RELEASE_FILE"
        return 1
    }
    local min
    case "${ID:-}" in
        debian) min=12 ;;
        ubuntu) min=24.04 ;;
        *)      min="" ;;
    esac
    if [[ -z "$min" ]] || ! dpkg --compare-versions "${VERSION_ID:-0}" ge "$min" 2>/dev/null; then
        err "仅支持 Debian 12+ / Ubuntu 24.04+"
        return 1
    fi
    return 0
}

check_kernel() {
    require_commands awk || return 1
    local major
    major=$(uname -r | awk -F. '{print $1+0}')
    if (( major < 6 )); then
        err "当前内核 $(uname -r) 过旧，本脚本要求内核 6.0 及以上"
        echo "  Debian 12 默认内核 6.1、Ubuntu 24.04 默认内核 6.8，请先升级系统"
        return 1
    fi
    return 0
}

check_bbr_available() {
    require_commands grep || return 1
    if grep -qw bbr "$TCP_AVAILABLE_FILE" 2>/dev/null; then
        return 0
    fi
    require_commands modprobe || return 1
    info "bbr 模块未加载，尝试加载..."
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr "$TCP_AVAILABLE_FILE" 2>/dev/null; then
        ok "bbr 模块加载成功"
        return 0
    fi
    return 1
}

#-------------------------------------------------------------
# 网络参数文件清理
#-------------------------------------------------------------

# 判断文件是否包含"生效的"网络参数
has_net_params() {
    grep -qE '^[[:space:]]*net\.' "$1" 2>/dev/null
}

# 找出所有包含网络参数的 sysctl 文件
find_net_files() {
    local d f real in_dir
    declare -A seen=()
    for d in $SYSCTL_DIRS; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.conf; do
            [[ -f "$f" ]] || continue
            if has_net_params "$f"; then
                real=$(readlink -f "$f")
                if [[ -z "${seen[$real]:-}" ]]; then
                    echo "$f"
                    seen[$real]=1
                fi
            fi
        done
    done
    # /etc/sysctl.conf
    if [[ -e "$SYSCTL_CONF" ]]; then
        real=$(readlink -f "$SYSCTL_CONF")
        in_dir=0
        for d in $SYSCTL_DIRS; do
            case "$real" in
                "$d"/*) in_dir=1 ;;
            esac
        done
        if [[ $in_dir -eq 0 ]] && has_net_params "$SYSCTL_CONF"; then
            echo "$SYSCTL_CONF"
        fi
    fi
}

# 删除所有网络参数文件，执行前列出清单并确认
delete_net_files() {
    local f ans files status=0
    require_commands grep readlink rm || return 1
    mapfile -t files < <(find_net_files)
    if (( ${#files[@]} == 0 )); then
        info "未发现网络相关 sysctl 参数文件，无需清理"
        return 0
    fi
    warn "以下文件将被永久删除（不做备份，匹配文件中的其他 net.* 参数也会一并删除）："
    for f in "${files[@]}"; do
        echo -e "    ${RED}✗${NC} $f"
    done
    if ! read -r -p "确认删除？[y/N] " ans; then
        warn "未读取到确认输入，已取消操作"
        return 1
    fi
    case "$ans" in
        y|Y) ;;
        *) warn "已取消操作"; return 1 ;;
    esac
    for f in "${files[@]}"; do
        if rm -f -- "$f"; then
            info "已删除 $f"
        else
            err "删除失败: $f"
            status=1
        fi
    done
    # /usr/lib /usr/local/lib 下为系统包文件，删除后 apt 升级可能恢复
    if (( ${#files[@]} > 0 )) && grep -qE '^/usr/(local/)?lib/sysctl\.d/' <<<"${files[*]}"; then
        warn "已删除系统包文件。"
        warn "重启后相关防护参数将恢复内核默认，apt 升级对应软件包时该文件可能被重新生成"
    fi
    return "$status"
}

#-------------------------------------------------------------
# 开启 BBR: 写入独立配置文件，与其他调优叠加生效
#-------------------------------------------------------------

enable_bbr() {
    local initial_system_failed=0 fallback=0

    check_root || return 1
    require_commands sysctl || return 1
    check_os || return 1
    check_kernel || return 1
    if ! check_bbr_available; then
        err "当前内核不支持 BBR，无法开启"
        return 1
    fi

    echo
    info "第 1 步 / 共 2 步：写入 BBR 配置"
    if ! write_config_atomic "$CONF_FILE" <<'EOF'
# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    then
        err "BBR 配置写入失败，未报告成功"
        return 1
    fi
    ok "已写入 $CONF_FILE"

    info "第 2 步 / 共 2 步：应用并验证"
    if ! apply_sysctl_system > /dev/null; then
        initial_system_failed=1
        err "sysctl --system 应用失败；配置文件已保留，运行时状态仍需验证"
    fi
    if ! sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1; then
        err "无法立即启用 BBR；配置文件已保留但未完成应用"
        return 1
    fi

    if sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1; then
        ok "队列调度 = fq"
    else
        warn "fq 队列不可用，降级为仅开启 BBR"
        fallback=1
        if ! write_config_atomic "$CONF_FILE" <<'EOF'
net.ipv4.tcp_congestion_control = bbr
EOF
        then
            err "BBR 降级配置写入失败；原配置文件仍可能保留"
            return 1
        fi
        warn "已将持久化配置降级为仅 BBR"
        if ! apply_sysctl_system > /dev/null; then
            err "降级后的 sysctl --system 应用仍失败；配置文件已保留"
            return 1
        fi
        if ! sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1; then
            err "降级后无法立即启用 BBR"
            return 1
        fi
    fi

    if (( fallback )); then
        if ! verify_sysctl_value net.ipv4.tcp_congestion_control bbr; then
            err "验证失败，降级后的 BBR 未生效"
            return 1
        fi
        ok "BBR 已启用（未启用 fq）"
        echo "  拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
        warn "当前队列调度未切换为 fq；BBR 配置已持久化"
    elif ! verify_sysctl_values \
        net.ipv4.tcp_congestion_control bbr \
        net.core.default_qdisc fq; then
        err "验证失败，BBR 未生效"
        return 1
    else
        if (( initial_system_failed )); then
            err "sysctl --system 曾应用失败，未将本次操作报告为完全成功"
            return 1
        fi
        ok "BBR 已启用"
        echo "  拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
        echo "  默认队列: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    fi

    info "提示: 现有网卡队列将在重启后统一生效；BBR 与调优配置互不冲突，可叠加"
    return 0
}

#-------------------------------------------------------------
# 删除全部配置: 清理所有网络参数文件，恢复默认
#-------------------------------------------------------------

disable_bbr() {
    local status=0

    check_root || return 1
    require_commands sysctl || return 1
    echo
    info "删除所有网络相关 sysctl 参数文件"
    delete_net_files || return 1

    # 重新应用剩余配置，并立即恢复 BBR 相关运行时值
    if ! apply_sysctl_system > /dev/null; then
        err "删除后 sysctl --system 应用失败"
        status=1
    fi
    if ! sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1; then
        err "无法恢复拥塞控制为 cubic"
        status=1
    fi
    if ! sysctl -w net.core.default_qdisc=pfifo_fast > /dev/null 2>&1; then
        err "无法恢复默认队列为 pfifo_fast"
        status=1
    fi
    if ! verify_sysctl_values \
        net.ipv4.tcp_congestion_control cubic \
        net.core.default_qdisc pfifo_fast; then
        status=1
    fi
    if (( status != 0 )); then
        err "配置文件已删除，但运行时恢复未完全成功"
        return 1
    fi

    ok "BBR、调优与高并发配置已全部删除，拥塞控制已恢复默认"
    info "其余网络参数将在重启后恢复内核默认"
    return 0
}

#-------------------------------------------------------------
# TCP 调优: 按带宽×延迟计算缓冲区 → 写入独立配置文件
#-------------------------------------------------------------

# 解析带宽输入为 bps。支持格式: 1000 / 500M / 1G / 100K / 1Gbps / 200Mbps / 125MB/s
# 裸数字按 Mbps 处理；字节速率自动 ×8 转比特速率
# 成功: 输出整数 bps 并返回 0；格式错误: 返回 1；空输入: 返回 2
parse_bw() {
    local input num unit mult byte bps
    [[ $# -eq 1 ]] || return 1
    input=${1// /}
    [[ -z "$input" ]] && return 2
    input=$(tr '[:upper:]' '[:lower:]' <<<"$input")
    byte=1
    case "$input" in
        *b/s) byte=8; input=${input%b/s} ;;
    esac
    input=$(sed -E 's/(bps|bit)$//' <<<"$input")
    num=$(sed -E 's/[a-z]+$//' <<<"$input")
    unit=${input#"$num"}
    [[ "$num" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    case "$unit" in
        "")    mult=1000000 ;;    # 裸数字按 Mbps
        k|kb)  mult=1000 ;;
        m|mb)  mult=1000000 ;;
        g|gb)  mult=1000000000 ;;
        *)     return 1 ;;
    esac
    if ! bps=$(awk -v n="$num" -v m="$mult" -v b="$byte" 'BEGIN {
        value = n * m * b
        if (value != value || value <= 0 || value > 9000000000000000000) exit 1
        printf "%.0f", value
    }'); then
        return 1
    fi
    [[ "$bps" =~ ^[0-9]+$ ]] || return 1
    echo "$bps"
    return 0
}

# 解析延迟输入为毫秒。支持格式: 20 / 30ms / 0.5s / 1000
# 裸数字按 ms 处理。成功: 输出毫秒并返回 0；格式错误: 返回 1；空输入: 返回 2
parse_rtt() {
    local input num unit mult ms
    [[ $# -eq 1 ]] || return 1
    input=${1// /}
    [[ -z "$input" ]] && return 2
    input=$(tr '[:upper:]' '[:lower:]' <<<"$input")
    num=$(sed -E 's/(ms|s)$//' <<<"$input")
    unit=${input#"$num"}
    [[ "$num" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    case "$unit" in
        ""|ms) mult=1 ;;
        s)     mult=1000 ;;
        *)     return 1 ;;
    esac
    if ! ms=$(awk -v n="$num" -v m="$mult" 'BEGIN {
        value = n * m
        if (value != value || value <= 0 || value > 9000000000000000000) exit 1
        printf "%.3f", value
    }'); then
        return 1
    fi
    awk -v ms="$ms" 'BEGIN { exit (ms <= 0) }' || return 1
    echo "$ms"
    return 0
}

calculate_bdp() {
    [[ $# -eq 2 ]] || return 1
    awk -v b="$1" -v m="$2" 'BEGIN {
        bdp = b * m / 8000
        buf = bdp * 2
        if (b <= 0 || m <= 0 || bdp != bdp || buf != buf || bdp < 0 || buf < 0 ||
            bdp > 9000000000000000000 || buf > 9000000000000000000) {
            exit 1
        }
        printf "%.0f %.0f\n", bdp, buf
    }'
}

# 字节数转人类可读大小
human_size() {
    [[ $# -eq 1 ]] || return 1
    awk -v b="$1" 'BEGIN {
        if (b >= 1048576) printf "%.1f MB", b / 1048576
        else if (b >= 1024) printf "%.1f KB", b / 1024
        else printf "%d B", b
    }'
}

tune_tcp() {
    local bw='' rtt='' bps='' ms='' calculation='' bdp='' buf='' dflt=''
    local mem_total='' mem_cap='' ans='' cur_rmem='' cur_wmem='' r
    local min_buf=1048576 max_buf=67108864

    check_root || return 1
    require_commands awk grep sed sysctl dpkg || return 1
    check_os || return 1
    echo
    info "第 1 步 / 共 2 步：输入网络参数"
    echo -e "  带宽格式: ${BLUE}1000 / 500M / 1G / 1Gbps / 125MB/s${NC}"
    while :; do
        if ! read -r -p "  请输入网络带宽: " bw; then
            warn "未读取到带宽输入，已取消操作"
            return 1
        fi
        bps=$(parse_bw "$bw"); r=$?
        (( r == 2 )) && { warn "已取消操作"; return 1; }
        (( r == 0 )) && break
        err "  带宽格式无效，请参考示例重新输入"
    done
    echo -e "  延迟格式: ${BLUE}20 / 30ms / 0.5s${NC}"
    while :; do
        if ! read -r -p "  请输入连接延迟 RTT: " rtt; then
            warn "未读取到 RTT 输入，已取消操作"
            return 1
        fi
        ms=$(parse_rtt "$rtt"); r=$?
        (( r == 2 )) && { warn "已取消操作"; return 1; }
        (( r == 0 )) && break
        err "  延迟格式无效，请参考示例重新输入"
    done

    # BDP = 带宽 × 延迟 / 8；缓冲区上限取 2×BDP
    if ! calculation=$(calculate_bdp "$bps" "$ms"); then
        err "带宽与 RTT 的计算结果超出可安全处理的范围"
        return 1
    fi
    if ! read -r bdp buf <<< "$calculation" ||
        [[ ! "$bdp" =~ ^[0-9]+$ || ! "$buf" =~ ^[0-9]+$ ]]; then
        err "无法解析 BDP 计算结果"
        return 1
    fi
    if (( buf > max_buf )); then
        warn "  缓冲区计算值 $(human_size "$buf") 超 64MB 上限，已截断"
        buf=$max_buf
    fi
    (( buf < min_buf )) && buf=$min_buf

    mem_total=$(awk '/^MemTotal:/ {print $2; exit}' "$MEMINFO_FILE" 2>/dev/null || true)
    if [[ "$mem_total" =~ ^[0-9]+$ ]] &&
        awk -v k="$mem_total" 'BEGIN { exit !(k > 0) }'; then
        if ! mem_cap=$(awk -v k="$mem_total" 'BEGIN {
            value = k * 1024 / 8
            if (value <= 0 || value > 9000000000000000000) exit 1
            printf "%.0f", value
        }'); then
            err "无法安全计算系统内存上限"
            return 1
        fi
        if [[ ! "$mem_cap" =~ ^[0-9]+$ ]]; then
            err "系统内存上限格式无效"
            return 1
        fi
        if (( mem_cap < min_buf )); then
            err "系统总内存的 1/8 小于 1MB，无法同时满足缓冲区安全边界"
            return 1
        fi
        if (( buf > mem_cap )); then
            warn "  缓冲区超系统总内存 1/8，已按内存限制调整"
            buf=$mem_cap
        fi
    fi
    dflt=$(( buf / 2 ))
    (( dflt > 4194304 )) && dflt=4194304
    (( dflt < 262144 )) && dflt=262144

    echo
    info "计算摘要:"
    echo "  带宽: $bw / 延迟: $rtt"
    echo "  BDP ≈ $(human_size "$bdp")"
    echo "  缓冲区上限: $(human_size "$buf")"
    echo "  默认缓冲区: $(human_size "$dflt")"
    if ! read -r -p "  确认写入？[y/N] " ans; then
        warn "未读取到确认输入，已取消操作"
        return 1
    fi
    case "$ans" in
        y|Y) ;;
        *) warn "已取消操作"; return 1 ;;
    esac

    info "第 2 步 / 共 2 步：写入并应用"
    if ! write_config_atomic "$TUNE_CONF" <<EOF
# TCP 缓冲区调优
# 带宽 ${bw} × 延迟 ${rtt} → BDP ≈ $(human_size "$bdp")，缓冲区上限取 2×BDP
net.core.rmem_max = $buf
net.core.wmem_max = $buf
net.ipv4.tcp_rmem = 4096 $dflt $buf
net.ipv4.tcp_wmem = 4096 $dflt $buf
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072   # 高吞吐低延迟：未发送数据阈值
EOF
    then
        err "TCP 调优配置写入失败，未报告成功"
        return 1
    fi
    ok "已写入 $TUNE_CONF"
    if ! apply_sysctl_system > /dev/null; then
        err "TCP 调优配置已保存，但 sysctl --system 应用失败"
        return 1
    fi
    if ! verify_sysctl_values \
        net.core.rmem_max "$buf" \
        net.core.wmem_max "$buf" \
        net.ipv4.tcp_rmem "4096 $dflt $buf" \
        net.ipv4.tcp_wmem "4096 $dflt $buf" \
        net.ipv4.tcp_slow_start_after_idle 0 \
        net.ipv4.tcp_notsent_lowat 131072; then
        err "验证失败，TCP 调优未完全生效"
        return 1
    fi
    cur_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
    cur_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)
    ok "TCP 缓冲区已应用"
    echo "  rmem_max / wmem_max: $(human_size "$buf")"
    echo "  tcp_rmem: $cur_rmem"
    echo "  tcp_wmem: $cur_wmem"
    echo "  slow_start_after_idle: $(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"
    echo "  notsent_lowat: $(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)"
    info "提示: 调优与 BBR、高并发配置互不冲突，可叠加生效"
    return 0
}

#-------------------------------------------------------------
# 高并发调优: 大并发服务器阈值参数 → 写入独立配置文件
#-------------------------------------------------------------

tune_concurrency() {
    check_root || return 1
    require_commands awk grep sed sysctl dpkg || return 1
    check_os || return 1
    echo
    info "第 1 步 / 共 2 步：写入高并发阈值参数"
    if ! write_config_atomic "$CONC_CONF" <<'EOF'
# 服务器高并发阈值调优
net.core.somaxconn = 65535                # 监听队列上限
net.ipv4.tcp_max_syn_backlog = 65535      # SYN 队列
net.core.netdev_max_backlog = 65536       # 网卡收包队列
net.ipv4.ip_local_port_range = 1024 65535 # 本地端口池
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30             # FIN-WAIT-2 超时
EOF
    then
        err "高并发配置写入失败，未报告成功"
        return 1
    fi
    ok "已写入 $CONC_CONF"

    info "第 2 步 / 共 2 步：应用并验证"
    if ! apply_sysctl_system > /dev/null; then
        err "高并发配置已保存，但 sysctl --system 应用失败"
        return 1
    fi
    if ! verify_sysctl_values \
        net.core.somaxconn 65535 \
        net.ipv4.tcp_max_syn_backlog 65535 \
        net.core.netdev_max_backlog 65536 \
        net.ipv4.ip_local_port_range "1024 65535" \
        net.ipv4.tcp_syncookies 1 \
        net.ipv4.tcp_fin_timeout 30; then
        err "验证失败，高并发阈值未完全生效"
        return 1
    fi
    ok "高并发阈值已应用"
    echo "  somaxconn: $(sysctl -n net.core.somaxconn 2>/dev/null)"
    echo "  tcp_max_syn_backlog: $(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null)"
    echo "  netdev_max_backlog: $(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
    echo "  ip_local_port_range: $(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null)"
    echo "  tcp_syncookies: $(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)"
    echo "  tcp_fin_timeout: $(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null)"
    info "提示: 高并发与 BBR、调优配置互不冲突，可叠加生效"
    return 0
}

#-------------------------------------------------------------
# 交互菜单
#-------------------------------------------------------------

show_menu() {
    local cc rmem
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    clear
    echo -e "${BOLD}  Debian BBR 一键管理脚本${NC}"
    echo "────────────────────────────────────────────"
    echo "  1) 开启 BBR"
    echo "  2) 删除全部配置"
    echo "  3) TCP 调优"
    echo "  4) 高并发调优"
    echo "  0) 退出"
    echo "────────────────────────────────────────────"
    echo -e "  当前拥塞控制: ${cc:-未设置}    缓冲区上限: $(human_size "${rmem:-0}")"
}

main() {
    local choice=''

    require_commands awk grep sed readlink sysctl dpkg || return 1
    check_root || return 1
    while true; do
        show_menu
        if ! read -r -p "  请选择 [0-4]: " choice; then
            warn "未读取到菜单输入，已退出"
            return 0
        fi
        case "$choice" in
            1) enable_bbr ;;
            2) disable_bbr ;;
            3) tune_tcp ;;
            4) tune_concurrency ;;
            0) echo "  已退出"; return 0 ;;
            *) warn "  无效输入，请重新选择" ;;
        esac
        echo
        if ! read -r -p "  按回车键返回菜单..."; then
            warn "未读取到返回菜单输入，已退出"
            return 0
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
