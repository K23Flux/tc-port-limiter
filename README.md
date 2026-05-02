# 🚦 tc-limit — LXC/NAT 容器端口限速管理器

[![Shell](https://img.shields.io/badge/shell-bash-4EAA25)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

适用于 LXC/NAT 容器的交互式端口限速脚本，基于 Linux Traffic Control (tc)。

---

## 解决的问题

在 NAT / LXC 容器中，服务流量可能走 `lo` (127.0.0.1) 回环网卡，传统 `tc` 规则对入站无效。本脚本通过 `ifb0` 虚拟网卡中转 `lo` 入站流量，并额外限制 `lo` 出站响应流量，配合 `eth0` 出站，实现**端口级别的双向限速**。

---

## 功能

- 📋 实时扫描监听端口（TCP/UDP）
- 🔍 查看当前所有限速规则（表格化展示）
- ⚡ 交互式添加端口限速（输入端口号 + KB/s）
- 🗑️ 精确删除单个端口限速
- ⚙️ 一键安装/卸载 systemd 开机自启
- 💾 规则持久化，重启后自动恢复

---

## 网络拓扑

```
        外部流量
           │
           ▼
    ┌──────────┐      ┌──────┐      ┌────────────┐
    │   eth0   │─────▶│  lo  │─────▶│  sing-box   │
    │          │      │      │      │   :48189   │
    └────┬─────┘      └──┬───┘      └────────────┘
         │               │
     tc egress       tc ingress (mirror)
  src_port 48189→        │
  rate 400kbit     ┌────▼──────┐
                   │   ifb0    │
                   │ dst_port→│
                   │  400kbit  │
                   └───────────┘

                  lo egress
               src_port 48189→
                 rate 400kbit
```

- **eth0 出站**: 按 TCP/UDP 分别匹配 `ip_proto` + `src_port`，限制服务发出的响应流量
- **ifb0 入站**: 按 TCP/UDP 分别匹配 `ip_proto` + `dst_port`，限制进入服务的请求流量（由 lo ingress 镜像而来）
- **lo 出站**: 按 TCP/UDP 分别匹配 `ip_proto` + `src_port`，限制 `127.0.0.1:端口` 返回本地转发端的响应流量

---

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/K23Flux/tc-port-limiter/main/tc-limit.sh -o /usr/local/bin/tc-limit.sh && chmod +x /usr/local/bin/tc-limit.sh && tc-limit.sh
```

一行命令完成下载、授权、启动。

---

## 使用方式

### 交互式菜单

```bash
./tc-limit.sh
```

```
╔══════════════════════════════════════════╗
║        🚦 TC 端口限速管理器               ║
║        LXC / NAT 容器专用                ║
╚══════════════════════════════════════════╝

  外网接口:   eth0
  ifb0 状态:  可用 ✓
  规则文件:   /etc/tc-limit/rules.conf
  开机自启:   未启用
  服务状态:   未运行

  [1] 📋 查看监听端口
  [2] 🔍 查看限速规则
  [3] ⚡ 添加端口限速
  [4] 🗑️  删除端口限速
  [5] ⚙️  开机自启管理
  [0] 🚪 退出
```

### 命令行模式

| 命令 | 作用 |
|------|------|
| `./tc-limit.sh` | 进入交互式菜单 |
| `./tc-limit.sh status` | 查看当前状态和规则 |
| `./tc-limit.sh install` | 一键安装开机自启并立即恢复持久化规则 |
| `./tc-limit.sh uninstall` | 卸载开机自启 |
| `./tc-limit.sh load` | 从配置文件恢复所有规则 |
| `./tc-limit.sh unload-all` | 清除所有规则 |

---

## 常见用法示例

```bash
# 给 48189 端口限速 50KB/s
./tc-limit.sh
> [3] 添加端口限速
> 端口: 48189
> 速率: 50

# 查看当前规则
./tc-limit.sh status

# 安装开机自启并立即启动服务
./tc-limit.sh install
```

安装后 `tc-limit.service` 会立即执行一次 `load`，菜单中的服务状态应显示为运行中。服务停止时只清除当前内核中的 tc 规则，不会清空 `/etc/tc-limit/rules.conf`。

---

## 速率换算

| KB/s | kbit | 适用场景 |
|------|------|---------|
| 10 | 80 | 极低带宽 |
| 50 | 400 | 中转轻量代理 |
| 100 | 800 | 网页浏览 |
| 500 | 4000 | 流畅视频 |
| 1000 | 8000 | 高速中转 |

> **公式**: kbit = KB/s × 8  
> 脚本内部自动换算，你只需输入 KB/s 数值。

---

## 依赖

| 工具 | 用途 |
|------|------|
| `tc` | 流量控制命令行工具 (iproute2) |
| `ss` | 端口扫描 (iproute2) |
| `ip` | 网络接口管理 (iproute2) |
| `modprobe` | 加载 ifb 内核模块 |
| `systemctl` | systemd 服务管理 (可选) |

```bash
# Debian/Ubuntu
apt install -y iproute2 kmod

# Alpine
apk add iproute2 kmod
```

---

## 文件结构

```
/usr/local/bin/tc-limit.sh              主脚本
/etc/tc-limit/rules.conf                规则持久化配置
/etc/systemd/system/tc-limit.service    systemd 服务 (安装后生成)
```

`rules.conf` 格式:

```
PORT|KBPS|ETH_MINOR|IFB_MINOR
48189|50|bc3d|bc3d
8080|100|1f90|1f90
```

---

## 技术细节

| 项目 | 值 |
|------|-----|
| 分类器 | `flower` (内核 3.x+) |
| HTB root handle | `10:` (eth0) / `20:` (ifb0) / `30:` (lo) |
| classid 编码 | 端口号转十六进制后用作 HTB minor handle，例如 `48189` → `bc3d` |
| 默认 class | `10:ffff` / `20:ffff` / `30:ffff` (10000mbit, 不限速) |
| 协议 | IPv4，TCP/UDP 各生成一条 `flower` filter，并显式指定 `ip_proto` |
| 镜像规则 | lo ingress → u32 match-all → mirred redirect → ifb0 |

---

## 故障排查

### ifb0 不可用

```
[!] 无法创建 ifb0 (可能内核不支持 ifb)
```

检查内核是否编译了 ifb 支持：

```bash
modprobe ifb
lsmod | grep ifb
```

若内核不支持，可重新编译内核启用 `CONFIG_IFB=y` 或升级内核。

### tc filter 添加失败

```
[✗] 添加 eth0 filter 失败 (port=48189)
```

检查是否有其他 tc 规则冲突：

```bash
tc qdisc show
tc filter show dev eth0
tc filter show dev ifb0
tc filter show dev lo
tc filter show dev lo parent ffff:
```

如果手动写 `flower src_port` 或 `flower dst_port`，需要同时指定 `ip_proto tcp` 或 `ip_proto udp`，否则部分系统会报 `Illegal "src_port"` / `Illegal "dst_port"`。

### 出站计数不增长

如果 `tc -s class show dev eth0` 中端口 class 一直是 `0 bytes`，但 `ss -tnp` 显示服务连接都在 `127.0.0.1:端口` 上，说明响应流量走的是回环接口。此时应查看 `lo` 出站 class：

```bash
tc -s class show dev lo
tc filter show dev lo
```

### 规则持久化不生效

检查 systemd 日志：

```bash
journalctl -u tc-limit.service -n 30
```

如果菜单显示“已启用”但“未运行”，重新执行一次安装命令即可更新 unit 并立即启动服务：

```bash
./tc-limit.sh install
```

---

## 局限性

- 仅支持 IPv4（IPv6 需额外 flower 规则）
- 仅匹配传输层端口 (TCP/UDP)
- LXC 特权容器可能无法加载内核模块 (需在宿主机操作)
- 重启后规则需要 systemd 服务恢复

---

## License

MIT
