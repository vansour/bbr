# Debian BBR 一键管理脚本（干净写入版）

采用"干净写入"策略：任何操作都不做备份，直接删除所有包含网络参数（`net.*`）的
sysctl 配置文件，保证系统上不存在任何可能影响 BBR 的旧参数残留。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vansour/bbr/main/bbr.sh)
```

## 适用系统

- Debian 9+ / Ubuntu 16.04+（内核需 4.9 及以上，脚本会自动检测）

## 用法

```bash
sudo bash bbr.sh
```

交互菜单：

```
  1) 开启 BBR（清理全部网络参数文件后重新写入）
  2) 删除 BBR（清理全部网络参数文件）
  0) 退出
```

## 操作说明

| 操作 | 行为 |
|---|---|
| 开启 BBR | 删除所有含 `net.*` 参数的 sysctl 文件 → 干净写入 `/etc/sysctl.d/99-bbr.conf`（bbr + fq）→ 立即应用并验证 |
| 删除 BBR | 删除所有含 `net.*` 参数的 sysctl 文件 → 恢复拥塞控制为默认 cubic |

清理范围：`/run/sysctl.d`、`/etc/sysctl.d`、`/usr/local/lib/sysctl.d`、
`/usr/lib/sysctl.d` 及 `/etc/sysctl.conf`（符号链接按真实文件去重，注释行不计）。

## 重要风险提示

- **无备份，不可恢复**。执行前会列出待删除文件清单并要求确认。
- 可能被删除的文件包括：
  - `/etc/sysctl.conf` 或 `/etc/sysctl.d/99-sysctl.conf`（Debian 上两者为同一文件，
    若手动设置过 `ip_forward` 等参数，删除后 NAT/路由配置将失效）
  - `/usr/lib/sysctl.d/50-default.conf`（procps 包文件，含 `rp_filter=2` 反欺骗、
    `accept_source_route=0` 等安全默认。删除后重启恢复内核默认，apt 升级时可能重新生成）
- 其余未写入的运行时参数（如 `ip_forward`）在重启后恢复内核默认。
- fq 在部分虚拟化环境不可用，脚本自动降级为仅开启 BBR。
