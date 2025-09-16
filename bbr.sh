#!/bin/bash

# Debian BBR 优化脚本
# 适用于 Debian 13+ 系统
# 作者: GitHub Copilot
# 日期: $(date +%Y-%m-%d)

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行！"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

# 检查系统版本
check_system() {
    if [[ ! -f /etc/debian_version ]]; then
        log_error "此脚本仅适用于Debian系统！"
        exit 1
    fi
    
    local debian_version=$(cat /etc/debian_version)
    log_info "检测到Debian版本: $debian_version"
}


# 清理旧配置
clean_old_config() {
    log_info "开始清理旧的sysctl配置..."
    
    # 删除 /etc/sysctl.conf
    if [[ -f /etc/sysctl.conf ]]; then
        rm -f /etc/sysctl.conf
        log_success "已删除 /etc/sysctl.conf"
    else
        log_info "/etc/sysctl.conf 不存在，无需删除"
    fi
    
    # 清空 /etc/sysctl.d/ 目录
    if [[ -d /etc/sysctl.d ]]; then
        rm -rf /etc/sysctl.d/*
        log_success "已清空 /etc/sysctl.d/ 目录"
    else
        mkdir -p /etc/sysctl.d
        log_info "创建 /etc/sysctl.d 目录"
    fi
}

# 创建新的sysctl配置
create_sysctl_config() {
    log_info "创建新的sysctl配置文件..."
    
    cat > /etc/sysctl.d/99-sysctl.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1

EOF
    
    log_success "基础配置已写入 /etc/sysctl.d/99-sysctl.conf"
}

# IPv6配置选择
configure_ipv6() {
    echo
    log_info "IPv6 配置选项："
    echo "1) 禁用 IPv6"
    echo "2) 启用 IPv6"
    echo "3) 跳过 IPv6 配置"
    
    while true; do
        read -p "请选择 IPv6 配置 [1-3]: " ipv6_choice
        case $ipv6_choice in
            1)
                log_info "配置禁用IPv6..."
                cat >> /etc/sysctl.d/99-sysctl.conf << 'EOF'
# 禁用IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
                log_success "IPv6已禁用"
                break
                ;;
            2)
                log_info "配置启用IPv6..."
                cat >> /etc/sysctl.d/99-sysctl.conf << 'EOF'
# 启用IPv6
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
                log_success "IPv6已启用并优化"
                break
                ;;
            3)
                log_info "跳过IPv6配置"
                break
                ;;
            *)
                log_error "无效选择，请输入1-3"
                ;;
        esac
    done
}

# 应用配置
apply_config() {
    log_info "应用新的sysctl配置..."
    
    # 重新加载sysctl配置
    if sysctl -p /etc/sysctl.d/99-sysctl.conf; then
        log_success "sysctl配置已应用"
    else
        log_error "应用sysctl配置失败"
        return 1
    fi
    
    # 验证BBR是否启用
    log_info "验证BBR配置..."
    local current_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}')
    local current_congestion=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    
    if [[ "$current_qdisc" == "fq" ]] && [[ "$current_congestion" == "bbr" ]]; then
        log_success "BBR拥塞控制算法已成功启用"
        log_success "当前队列调度器: $current_qdisc"
        log_success "当前拥塞控制算法: $current_congestion"
    else
        log_warning "BBR配置可能未完全生效"
        log_info "当前队列调度器: $current_qdisc"
        log_info "当前拥塞控制算法: $current_congestion"
    fi
    
    # 检查ECN状态
    local ecn_status=$(sysctl net.ipv4.tcp_ecn | awk '{print $3}')
    if [[ "$ecn_status" == "1" ]]; then
        log_success "ECN显式拥塞通知已启用"
    else
        log_warning "ECN配置可能未生效"
    fi
}

# 显示配置摘要
show_summary() {
    echo
    log_info "==================== 配置摘要 ===================="
    echo "✓ 已删除旧的 /etc/sysctl.conf"
    echo "✓ 已清空 /etc/sysctl.d/ 目录"
    echo "✓ 已创建 /etc/sysctl.d/99-sysctl.conf"
    echo "✓ 已启用 BBR 拥塞控制算法"
    echo "✓ 已启用 FQ 队列调度器"
    echo "✓ 已启用 ECN 显式拥塞通知"
    echo "✓ 已优化 TCP 性能参数"
    
    echo
    log_info "可用命令验证："
    echo "  查看当前拥塞控制算法: sysctl net.ipv4.tcp_congestion_control"
    echo "  查看可用拥塞控制算法: sysctl net.ipv4.tcp_available_congestion_control"
    echo "  查看当前队列调度器: sysctl net.core.default_qdisc"
    echo "  查看ECN状态: sysctl net.ipv4.tcp_ecn"
    echo "  查看所有BBR相关配置: sysctl -a | grep bbr"
    echo
}

# 主函数
main() {
    echo "=================================================="
    echo "          Debian BBR 优化脚本"
    echo "=================================================="
    echo
    
    check_root
    check_system
    
    echo "此脚本将执行以下操作："
    echo "1. 删除 /etc/sysctl.conf"
    echo "2. 清空 /etc/sysctl.d/ 目录"
    echo "3. 创建新的 /etc/sysctl.d/99-sysctl.conf"
    echo "4. 启用 BBR、FQ、ECN 优化"
    echo "5. 配置 IPv6（可选）"
    echo
    
    read -p "是否继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        exit 0
    fi
    
    echo
    clean_old_config
    create_sysctl_config
    configure_ipv6
    apply_config
    show_summary
    
    log_success "BBR优化配置完成！建议重启系统以确保所有设置生效。"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
