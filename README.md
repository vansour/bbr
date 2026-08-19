# Debian BBR 一键管理脚本

BBR、TCP 缓冲区调优、高并发阈值三套配置**互不冲突，可叠加生效**，
各自写入独立配置文件：

| 配置 | 文件 |
|---|---|
| BBR 拥塞控制 | `/etc/sysctl.d/99-bbr.conf` |
| TCP 调优 | `/etc/sysctl.d/99-bbr-tune.conf` |
| 高并发调优 | `/etc/sysctl.d/99-bbr-concurrency.conf` |

重复执行同一功能会覆盖自身文件；删除操作才清理配置，且不做备份。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vansour/bbr/main/bbr.sh)
```

## 适用系统

- Debian 12+ / Ubuntu 24.04+

## 用法

```bash
sudo bash bbr.sh
```

交互菜单：

```
  1) 开启 BBR    2) 删除全部配置
  3) TCP 调优    4) 高并发调优
  0) 退出
```

## 操作说明

| 操作 | 行为 |
|---|---|
| 开启 BBR | 写入 `99-bbr.conf`（fq + bbr）→ 立即应用并验证 |
| TCP 调优 | 写入 `99-bbr-tune.conf`（按输入的带宽×延迟计算缓冲区）→ 立即应用并验证 |
| 高并发调优 | 写入 `99-bbr-concurrency.conf`（大并发阈值参数）→ 立即应用并验证 |
| 删除全部配置 | 永久删除所有含 `net.*` 参数的 sysctl 文件（文件中的其他网络参数也可能被删除）→ 恢复拥塞控制为 cubic |

三个功能可任意组合、按任意顺序执行，参数互不覆盖；`sysctl --system`
会同时加载所有配置文件。

## TCP 调优

交互输入网络带宽与连接延迟，按 **BDP** 计算 socket 缓冲区：

```
BDP = 带宽 × 延迟 / 8
缓冲区上限 = 2 × BDP
```

- 输入仅支持纯数字：带宽单位固定为 **Mbps**（如 `1000`），延迟单位固定为 **ms**（如 `20`）；不再支持 `M`/`G`/`MB/s`/`s` 等后缀
- 写入参数：`net.core.rmem_max`、`net.core.wmem_max`、`net.ipv4.tcp_rmem`、`net.ipv4.tcp_wmem`、`net.ipv4.tcp_slow_start_after_idle = 0`、`net.ipv4.tcp_notsent_lowat = 131072`
- 缓冲区上限限制在 `[1MB, 64MB]` 内，且不超过系统总内存的 1/8，防止大 BDP 场景耗尽内存；默认缓冲区取上限的一半，并限制在 `256KB` 到 `4MB` 之间
- 脚本摘要中的 `KB`/`MB` 按 `1024` 进位显示；例如 `1G × 20ms` → BDP 约 `2.4 MB`（实际约 2.5 MB）→ 上限约 `4.8 MB`

## 高并发调优

面向高连接数服务器的阈值参数：

| 参数 | 写入值 | 默认 | 作用 |
|---|---|---|---|
| `net.core.somaxconn` | 65535 | 4096 | 监听队列上限 |
| `net.ipv4.tcp_max_syn_backlog` | 65535 | 2048 | SYN 队列 |
| `net.core.netdev_max_backlog` | 65536 | 1000 | 网卡收包队列 |
| `net.ipv4.ip_local_port_range` | 1024 65535 | 32768 60999 | 本地端口池 |
| `net.ipv4.tcp_syncookies` | 1 | 1 | 抗 SYN 洪水 |
| `net.ipv4.tcp_fin_timeout` | 30 | 60 | 缩短 FIN-WAIT-2 超时 |

## 内核 6.x 兼容性

脚本现有参数在 Linux 6.x 全部兼容、无废弃：`rmem/wmem`、`tcp_slow_start_after_idle`、`fq`、`bbr` 均正常生效。

6.x 新增/相关的 TCP 参数调研结论：

| 参数 | 引入版本 | 结论 |
|---|---|---|
| `tcp_plb_enabled` | 6.2 | 不写入：依赖 ECN + IPv6 flow label + 数据中心多路径，普通服务器无意义 |
| `tcp_pacing_ss_ratio` / `tcp_pacing_ca_ratio` | 5.0 | 不写入：BBR pacing 倍率默认已合理 |
| `tcp_mtu_probe_floor` | 6.7 | 不写入：需搭配 `tcp_mtu_probing=1`，改变路径 MTU 行为，非通用需求 |
| `tcp_backlog_ack_defer` | 6.8 | 不写入：收益小 |
| `tcp_gro` / `tcp_rw_reduction` / `tcp_rx_skb_copybreak` | — | 不存在：网上流传的 sysctl 实为 socket 选项或未合入主线 |

内核 6.x 确认纳入的参数：`tcp_notsent_lowat = 131072`。

## 重要风险提示

- 菜单 2 删除全部配置：**无备份，不可恢复**。执行前会列出待删除文件清单并要求确认；匹配文件中的其他 `net.*` 参数也可能一并删除。
- 可能被删除的文件包括：
  - `/etc/sysctl.d/99-bbr.conf`、`99-bbr-tune.conf`、`99-bbr-concurrency.conf`
  - `/etc/sysctl.conf` 或 `/etc/sysctl.d/99-sysctl.conf`
  - `/usr/lib/sysctl.d/50-default.conf`
- 其余未写入的运行时参数在重启后恢复内核默认。
- `pfifo_fast` 是脚本在删除配置时选择的恢复值，不代表所有系统原先的默认值；已有网卡队列可能要到重启后才统一变化。
- fq 在部分虚拟化环境不可用，脚本自动降级为仅开启 BBR。
