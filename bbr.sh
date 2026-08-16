#!/usr/bin/env bash
#=============================================================
# Debian / Ubuntu BBR 一键管理脚本
#
#  开启: 删除所有包含网络参数的 sysctl 文件 → 干净写入新配置
#  调优: 删除所有包含网络参数的 sysctl 文件 → 按带宽×延迟计算并写入缓冲区参数
#  并发: 删除所有包含网络参数的 sysctl 文件 → 写入服务器大并发阈值参数
#  删除: 删除所有包含网络参数的 sysctl 文件
#
#  所有操作不做任何备份
#  用法: sudo bash bbr.sh
#=============================================================

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

CONF_FILE="/etc/sysctl.d/99-bbr.conf"
SYSCTL_DIRS="/run/sysctl.d /etc/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d"

ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${BLUE}[·]${NC} $*"; }

#-------------------------------------------------------------
# 前置检查
#-------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "需要 root 权限，请使用: sudo bash $0"
        exit 1
    fi
}

check_os() {
    # shellcheck disable=SC1091
    . /etc/os-release
    local min
    case "${ID:-}" in
        debian) min=12 ;;
        ubuntu) min=24.04 ;;
        *)      min="" ;;
    esac
    if [[ -z "$min" ]] || ! dpkg --compare-versions "${VERSION_ID:-0}" ge "$min" 2>/dev/null; then
        err "仅支持 Debian 12+ / Ubuntu 24.04+"
        exit 1
    fi
}

check_kernel() {
    local major
    major=$(uname -r | awk -F. '{print $1+0}')
    if (( major < 6 )); then
        err "当前内核 $(uname -r) 过旧，本脚本要求内核 6.0 及以上"
        echo "  Debian 12 默认内核 6.1、Ubuntu 24.04 默认内核 6.8，请先升级系统"
        exit 1
    fi
}

check_bbr_available() {
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        return 0
    fi
    info "bbr 模块未加载，尝试加载..."
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
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
    if [[ -e /etc/sysctl.conf ]]; then
        real=$(readlink -f /etc/sysctl.conf)
        in_dir=0
        for d in $SYSCTL_DIRS; do
            case "$real" in
                "$d"/*) in_dir=1 ;;
            esac
        done
        if [[ $in_dir -eq 0 ]] && has_net_params /etc/sysctl.conf; then
            echo /etc/sysctl.conf
        fi
    fi
}

# 删除所有网络参数文件，执行前列出清单并确认
delete_net_files() {
    local f ans files
    mapfile -t files < <(find_net_files)
    if (( ${#files[@]} == 0 )); then
        info "未发现网络相关 sysctl 参数文件，无需清理"
        return 0
    fi
    warn "将永久删除以下文件："
    for f in "${files[@]}"; do
        echo -e "    ${RED}✗${NC} $f"
    done
    read -r -p "确认删除？[y/N] " ans
    case "$ans" in
        y|Y) ;;
        *) warn "已取消操作"; return 1 ;;
    esac
    for f in "${files[@]}"; do
        rm -f "$f" && info "已删除 $f"
    done
    # /usr/lib /usr/local/lib 下为系统包文件，删除后 apt 升级可能恢复
    if (( ${#files[@]} > 0 )) && grep -qE '^/usr/(local/)?lib/sysctl\.d/' <<<"${files[*]}"; then
        warn "已删除系统包文件。"
        warn "重启后相关防护参数将恢复内核默认，apt 升级对应软件包时该文件可能被重新生成"
    fi
    return 0
}

#-------------------------------------------------------------
# 开启 BBR: 清理全部网络参数文件 → 干净写入
#-------------------------------------------------------------

enable_bbr() {
    check_root
    check_os
    check_kernel
    if ! check_bbr_available; then
        err "当前内核不支持 BBR，无法开启"
        return 1
    fi

    echo
    info "第 1 步 / 共 3 步：清理所有网络相关 sysctl 参数文件"
    delete_net_files || return 1

    info "第 2 步 / 共 3 步：干净写入 BBR 配置"
    cat > "$CONF_FILE" <<'EOF'
# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    ok "已写入 $CONF_FILE"

    info "第 3 步 / 共 3 步：应用并验证"
    sysctl --system > /dev/null
    sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null
    if sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1; then
        ok "队列调度 = fq"
    else
        warn "fq 队列不可用，降级为仅开启 BBR"
        printf '%s\n' 'net.ipv4.tcp_congestion_control = bbr' > "$CONF_FILE"
    fi

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]]; then
        ok "BBR 已启用"
        echo "  拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
        echo "  默认队列: $(sysctl -n net.core.default_qdisc)"
        info "提示: 现有网卡队列将在重启后统一生效"
    else
        err "验证失败，BBR 未生效"
        return 1
    fi
}

#-------------------------------------------------------------
# 删除 BBR: 只清理所有网络参数文件
#-------------------------------------------------------------

disable_bbr() {
    check_root
    echo
    info "删除所有网络相关 sysctl 参数文件"
    delete_net_files || return 1

    # 重新应用剩余配置，并立即恢复 BBR 相关运行时值
    sysctl --system > /dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=pfifo_fast > /dev/null 2>&1 || true

    ok "BBR 已删除，拥塞控制已恢复默认"
    info "其余网络参数将在重启后恢复内核默认"
}

#-------------------------------------------------------------
# TCP 调优: 按带宽×延迟计算缓冲区 → 干净写入
#-------------------------------------------------------------

# 解析带宽输入为 bps。支持格式: 1000 / 500M / 1G / 100K / 1Gbps / 200Mbps / 125MB/s
# 裸数字按 Mbps 处理；字节速率自动 ×8 转比特速率
# 成功: 输出整数 bps 并返回 0；格式错误: 返回 1；空输入: 返回 2
parse_bw() {
    local input num unit mult byte bps
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
    bps=$(awk -v n="$num" -v m="$mult" -v b="$byte" 'BEGIN { printf "%.0f", n*m*b }')
    (( bps > 0 )) || return 1
    echo "$bps"
    return 0
}

# 解析延迟输入为毫秒。支持格式: 20 / 30ms / 0.5s / 1000
# 裸数字按 ms 处理。成功: 输出毫秒并返回 0；格式错误: 返回 1；空输入: 返回 2
parse_rtt() {
    local input num unit mult ms
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
    ms=$(awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.3f", n*m }')
    awk -v ms="$ms" 'BEGIN { exit (ms <= 0) }' || return 1
    echo "$ms"
    return 0
}

# 字节数转人类可读大小
human_size() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1048576) printf "%.1f MB", b / 1048576
        else if (b >= 1024) printf "%.1f KB", b / 1024
        else printf "%d B", b
    }'
}

tune_tcp() {
    check_root
    check_os
    echo
    info "第 1 步 / 共 3 步：清理所有网络相关 sysctl 参数文件"
    delete_net_files || return 1
    info "提示: 若之前开启过 BBR，其配置已随清理一并移除"

    local bw rtt bps ms bdp buf dflt mem_total mem_cap ans cur_max cur_rmem r
    info "第 2 步 / 共 3 步：输入网络参数"
    echo -e "  带宽格式: ${BLUE}1000 / 500M / 1G / 1Gbps / 125MB/s${NC}"
    while :; do
        read -r -p "  请输入网络带宽: " bw
        bps=$(parse_bw "$bw"); r=$?
        (( r == 2 )) && { warn "已取消操作"; return 1; }
        (( r == 0 )) && break
        err "  带宽格式无效，请参考示例重新输入"
    done
    echo -e "  延迟格式: ${BLUE}20 / 30ms / 0.5s${NC}"
    while :; do
        read -r -p "  请输入连接延迟 RTT: " rtt
        ms=$(parse_rtt "$rtt"); r=$?
        (( r == 2 )) && { warn "已取消操作"; return 1; }
        (( r == 0 )) && break
        err "  延迟格式无效，请参考示例重新输入"
    done

    # BDP = 带宽 × 延迟 / 8；缓冲区上限取 2×BDP
    read -r bdp buf <<< "$(awk -v b="$bps" -v m="$ms" 'BEGIN {
        bdp = b * m / 1000 / 8
        buf = 2 * bdp
        printf "%d %d", bdp, buf
    }')"
    if (( buf > 67108864 )); then
        warn "  缓冲区计算值 $(human_size "$buf") 超 64MB 上限，已截断"
        buf=67108864
    fi
    mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    if [[ -n "${mem_total:-}" && $mem_total -gt 0 ]]; then
        mem_cap=$(( mem_total * 1024 / 8 ))    # 总内存的 1/8
        if (( buf > mem_cap )); then
            warn "  缓冲区超系统总内存 1/8，已按内存限制调整"
            buf=$mem_cap
        fi
    fi
    (( buf < 1048576 )) && buf=1048576
    dflt=$(( buf / 2 ))
    (( dflt > 4194304 )) && dflt=4194304
    (( dflt < 262144 )) && dflt=262144

    echo
    info "计算摘要:"
    echo "  带宽: $bw / 延迟: $rtt"
    echo "  BDP ≈ $(human_size "$bdp")"
    echo "  缓冲区上限: $(human_size "$buf")"
    echo "  默认缓冲区: $(human_size "$dflt")"
    read -r -p "  确认写入？[y/N] " ans
    case "$ans" in
        y|Y) ;;
        *) warn "已取消操作"; return 1 ;;
    esac

    info "第 3 步 / 共 3 步：写入并应用"
    cat > "$CONF_FILE" <<EOF
# TCP 缓冲区调优
# 带宽 ${bw} × 延迟 ${rtt} → BDP ≈ $(human_size "$bdp")，缓冲区上限取 2×BDP
net.core.rmem_max = $buf
net.core.wmem_max = $buf
net.ipv4.tcp_rmem = 4096 $dflt $buf
net.ipv4.tcp_wmem = 4096 $dflt $buf
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072   # 高吞吐低延迟：未发送数据阈值
EOF
    ok "已写入 $CONF_FILE"
    sysctl --system > /dev/null

    cur_max=$(sysctl -n net.core.rmem_max 2>/dev/null)
    cur_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
    if [[ "$cur_max" == "$buf" ]]; then
        ok "TCP 缓冲区已应用"
        echo "  rmem_max / wmem_max: $(human_size "$cur_max")"
        echo "  tcp_rmem: $cur_rmem"
        echo "  tcp_wmem: $(sysctl -n net.ipv4.tcp_wmem)"
        echo "  slow_start_after_idle: $(sysctl -n net.ipv4.tcp_slow_start_after_idle)"
        echo "  notsent_lowat: $(sysctl -n net.ipv4.tcp_notsent_lowat)"
    else
        err "验证失败，缓冲区未生效"
        return 1
    fi
    info "提示: 本次调优不包含 BBR；如需开启 BBR 请选择菜单 1"
}

#-------------------------------------------------------------
# 高并发调优: 大并发服务器阈值参数 → 干净写入
#-------------------------------------------------------------

tune_concurrency() {
    check_root
    check_os
    echo
    info "第 1 步 / 共 3 步：清理所有网络相关 sysctl 参数文件"
    delete_net_files || return 1
    info "提示: 若之前开启过 BBR 或调优，其配置已随清理一并移除"

    info "第 2 步 / 共 3 步：写入高并发阈值参数"
    cat > "$CONF_FILE" <<'EOF'
# 服务器高并发阈值调优
net.core.somaxconn = 65535                # 监听队列上限
net.ipv4.tcp_max_syn_backlog = 65535      # SYN 队列
net.core.netdev_max_backlog = 65536       # 网卡收包队列
net.ipv4.ip_local_port_range = 1024 65535 # 本地端口池
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30             # 缩短 TIME_WAIT 回收
EOF
    ok "已写入 $CONF_FILE"

    info "第 3 步 / 共 3 步：应用并验证"
    sysctl --system > /dev/null
    if [[ "$(sysctl -n net.core.somaxconn 2>/dev/null)" == "65535" ]]; then
        ok "高并发阈值已应用"
        echo "  somaxconn: $(sysctl -n net.core.somaxconn)"
        echo "  tcp_max_syn_backlog: $(sysctl -n net.ipv4.tcp_max_syn_backlog)"
        echo "  netdev_max_backlog: $(sysctl -n net.core.netdev_max_backlog)"
        echo "  ip_local_port_range: $(sysctl -n net.ipv4.ip_local_port_range)"
        echo "  tcp_fin_timeout: $(sysctl -n net.ipv4.tcp_fin_timeout)"
    else
        err "验证失败，高并发阈值未生效"
        return 1
    fi
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
    echo "  2) 删除 BBR"
    echo "  3) TCP 调优"
    echo "  4) 高并发调优"
    echo "  0) 退出"
    echo "────────────────────────────────────────────"
    echo -e "  当前拥塞控制: ${cc:-未设置}    缓冲区上限: $(human_size "${rmem:-0}")"
}

while true; do
    show_menu
    read -r -p "  请选择 [0-4]: " choice
    case "$choice" in
        1) enable_bbr ;;
        2) disable_bbr ;;
        3) tune_tcp ;;
        4) tune_concurrency ;;
        0) echo "  已退出"; exit 0 ;;
        *) warn "  无效输入，请重新选择" ;;
    esac
    echo
    read -r -p "  按回车键返回菜单..." _
done
