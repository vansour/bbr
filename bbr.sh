#!/usr/bin/env bash
#=============================================================
# Debian / Ubuntu BBR 一键管理脚本（干净写入版）
#
#  开启: 删除所有包含网络参数的 sysctl 文件 → 干净写入新配置
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
    case "${ID:-}:${ID_LIKE:-}" in
        *debian*|*ubuntu*)
            return 0
            ;;
        *)
            err "仅支持 Debian/Ubuntu 系统 (当前: ${PRETTY_NAME:-未知})"
            exit 1
            ;;
    esac
}

check_kernel() {
    local major minor
    major=$(uname -r | awk -F. '{print $1+0}')
    minor=$(uname -r | awk -F. '{print $2+0}')
    if (( major < 4 || (major == 4 && minor < 9) )); then
        err "当前内核 $(uname -r) 过旧，BBR 需要内核 4.9 及以上"
        echo "  建议升级内核后再试"
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

# 判断文件是否包含"生效的"网络参数（net.*，排除注释行）
has_net_params() {
    grep -qE '^[[:space:]]*net\.' "$1" 2>/dev/null
}

# 找出所有包含网络参数的 sysctl 文件（符号链接按真实文件去重）
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
    # /etc/sysctl.conf (Debian 上通常是 /etc/sysctl.d/99-sysctl.conf 的符号链接，
    # 真实文件已在上面目录扫描中覆盖，这里只处理独立文件)
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
    warn "将永久删除以下文件（不做备份，不可恢复）："
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
        warn "已删除系统包文件（如 /usr/lib/sysctl.d/50-default.conf，含 rp_filter 等安全默认），"
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
# BBR 拥塞控制（由 bbr.sh 生成）
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
        warn "fq 队列不可用（虚拟化环境常见），降级为仅开启 BBR"
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

    ok "BBR 已删除，拥塞控制已恢复默认 (cubic)"
    info "其余网络参数将在重启后恢复内核默认"
}

#-------------------------------------------------------------
# 交互菜单
#-------------------------------------------------------------

show_menu() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    clear
    echo -e "${BOLD}  Debian BBR 一键管理脚本（干净写入版）${NC}"
    echo "────────────────────────────────────────────"
    echo "  1) 开启 BBR（清理全部网络参数文件后重新写入）"
    echo "  2) 删除 BBR（清理全部网络参数文件）"
    echo "  0) 退出"
    echo "────────────────────────────────────────────"
    echo -e "  当前拥塞控制: ${cc:-未设置}"
}

while true; do
    show_menu
    read -r -p "  请选择 [0-2]: " choice
    case "$choice" in
        1) enable_bbr ;;
        2) disable_bbr ;;
        0) echo "  已退出"; exit 0 ;;
        *) warn "  无效输入，请重新选择" ;;
    esac
    echo
    read -r -p "  按回车键返回菜单..." _
done
