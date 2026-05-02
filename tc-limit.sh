#!/usr/bin/env bash
# ============================================================================
# tc-limit.sh — LXC/NAT 容器端口限速管理器
# 速率单位: KB/s (输入纯数字即可，自动 ×8 换算 kbit)
#
# 用法:
#   ./tc-limit.sh             进入交互式菜单
#   ./tc-limit.sh status      查看当前状态和规则
#   ./tc-limit.sh install     安装 systemd 开机自启
#   ./tc-limit.sh uninstall   卸载开机自启
#   ./tc-limit.sh load        从配置文件恢复所有规则
#   ./tc-limit.sh unload-all  清除所有规则
# ============================================================================
set -euo pipefail

# ============================================================================
# 全局常量
# ============================================================================
readonly SCRIPT_PATH="${0}"
readonly RULES_DIR="/etc/tc-limit"
readonly RULES_CONF="${RULES_DIR}/rules.conf"
readonly SERVICE_FILE="/etc/systemd/system/tc-limit.service"
readonly ETH_ROOT_HANDLE="10:"
readonly IFB_ROOT_HANDLE="20:"
readonly DEFAULT_CLASS="ffff"
readonly DEFAULT_RATE_GBIT="10000"
readonly INGRESS_IF="ifb0"

OUT_IF="eth0"
HAS_IFB=0

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
fi

# ============================================================================
# 工具函数
# ============================================================================
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
hr()   { echo -e "${DIM}──────────────────────────────────────────────${NC}"; }

read_input() {
    local prompt_text="$1" default="$2" pattern="${3:-.*}" input
    while true; do
        if [[ -n "$default" ]]; then
            echo -en "${CYAN}${prompt_text}${NC} ${DIM}[${default}]${NC}: "
        else
            echo -en "${CYAN}${prompt_text}${NC}: "
        fi
        read -r input
        input="${input:-$default}"
        if [[ "$input" =~ ^${pattern}$ ]]; then
            echo "$input"
            return 0
        fi
        warn "输入无效，请重新输入"
    done
}

confirm() {
    local ans
    echo -en "${YELLOW}$1${NC} ${DIM}(y/N):${NC} "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ============================================================================
# 前置检查 & 初始化
# ============================================================================
check_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行此脚本"
}

check_deps() {
    local missing=()
    for cmd in tc ss ip modprobe; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "缺少依赖命令: ${missing[*]}"
}

detect_out_if() {
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [[ -n "$iface" ]] && ip link show "$iface" &>/dev/null 2>&1; then
        OUT_IF="$iface"
        info "检测到外网接口: ${BOLD}${OUT_IF}${NC}"
        return 0
    fi
    warn "无法自动检测外网接口，使用默认: ${BOLD}${OUT_IF}${NC}"
    return 1
}

init_ifb() {
    if ! lsmod 2>/dev/null | grep -q "^ifb "; then
        modprobe ifb 2>/dev/null && info "加载 ifb 内核模块" || {
            warn "ifb 模块加载失败 (可能已内建，继续尝试)"
        }
    fi

    if ! ip link show "${INGRESS_IF}" &>/dev/null 2>&1; then
        ip link add "${INGRESS_IF}" type ifb 2>/dev/null || {
            warn "无法创建 ${INGRESS_IF} 接口 (内核可能不支持 ifb)"
            HAS_IFB=0
            return 1
        }
        info "创建 ${INGRESS_IF} 接口"
    fi

    ip link set "${INGRESS_IF}" up 2>/dev/null || {
        warn "无法启用 ${INGRESS_IF} 接口"
        HAS_IFB=0
        return 1
    }

    if ! tc qdisc show dev lo 2>/dev/null | grep -q "ingress"; then
        tc qdisc add dev lo handle ffff: ingress 2>/dev/null || {
            warn "无法在 lo 上添加 ingress qdisc"
            HAS_IFB=0
            return 1
        }
        info "lo 已添加 ingress qdisc"
    fi

    if ! tc filter show dev lo parent ffff: 2>/dev/null | grep -q "ifb0"; then
        tc filter add dev lo parent ffff: protocol ip prio 1 u32 \
            match u32 0 0 \
            action mirred egress redirect dev "${INGRESS_IF}" 2>/dev/null || {
            warn "lo → ${INGRESS_IF} 镜像规则添加失败"
            HAS_IFB=0
            return 1
        }
        info "lo → ${INGRESS_IF} 镜像规则已添加"
    fi

    HAS_IFB=1
    ok "${INGRESS_IF} 初始化完成"
    return 0
}

init_all() {
    check_root
    check_deps
    detect_out_if
    mkdir -p "${RULES_DIR}"
    init_ifb
}

# ============================================================================
# TC 操作核心函数
# ============================================================================
ensure_root_qdisc() {
    local dev="$1" handle="$2"
    if ! tc qdisc show dev "$dev" 2>/dev/null | grep -q "htb"; then
        tc qdisc add dev "$dev" root handle "$handle" htb default "${DEFAULT_CLASS}" 2>/dev/null || {
            die "无法在 ${dev} 上创建 root qdisc (handle ${handle})"
        }
        tc class add dev "$dev" parent "${handle}" classid "${handle}${DEFAULT_CLASS}" \
            htb rate "${DEFAULT_RATE_GBIT}mbit" ceil "${DEFAULT_RATE_GBIT}mbit" 2>/dev/null || {
            die "无法在 ${dev} 上创建默认 class"
        }
    fi
}

is_port_limited() {
    local port="$1"
    tc class show dev "$OUT_IF" 2>/dev/null | grep -q "${ETH_ROOT_HANDLE}${port}\b"
}

add_limit() {
    local port="$1" kbps="$2"
    local kbit=$((kbps * 8))

    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "无效端口: $port"
    [[ "$kbps" =~ ^[0-9]+$ ]] && ((kbps > 0)) || die "无效速率: ${kbps}KB/s"

    if is_port_limited "$port"; then
        warn "端口 ${port} 已有限速规则，将更新为 ${kbps}KB/s"
        remove_limit "$port" true
    fi

    ensure_root_qdisc "$OUT_IF" "$ETH_ROOT_HANDLE"

    tc class add dev "$OUT_IF" parent "$ETH_ROOT_HANDLE" \
        classid "${ETH_ROOT_HANDLE}${port}" \
        htb rate "${kbit}kbit" ceil "${kbit}kbit" 2>/dev/null || {
        die "添加 eth0 class 失败 (port=${port}, rate=${kbit}kbit)"
    }

    tc filter add dev "$OUT_IF" parent "$ETH_ROOT_HANDLE" \
        protocol ip prio 1 flower \
        src_port "$port" \
        flowid "${ETH_ROOT_HANDLE}${port}" 2>/dev/null || {
        tc class del dev "$OUT_IF" classid "${ETH_ROOT_HANDLE}${port}" 2>/dev/null || true
        die "添加 eth0 filter 失败 (port=${port})"
    }

    info "eth0 出站 : 端口 ${port} → ${kbit}kbit (${kbps}KB/s)"

    if [[ "$HAS_IFB" -eq 1 ]]; then
        ensure_root_qdisc "$INGRESS_IF" "$IFB_ROOT_HANDLE"

        tc class add dev "$INGRESS_IF" parent "$IFB_ROOT_HANDLE" \
            classid "${IFB_ROOT_HANDLE}${port}" \
            htb rate "${kbit}kbit" ceil "${kbit}kbit" 2>/dev/null || {
            die "添加 ifb0 class 失败 (port=${port})"
        }

        tc filter add dev "$INGRESS_IF" parent "$IFB_ROOT_HANDLE" \
            protocol ip prio 1 flower \
            dst_port "$port" \
            flowid "${IFB_ROOT_HANDLE}${port}" 2>/dev/null || {
            tc class del dev "$INGRESS_IF" classid "${IFB_ROOT_HANDLE}${port}" 2>/dev/null || true
            die "添加 ifb0 filter 失败 (port=${port})"
        }

        info "ifb0 入站 : 端口 ${port} → ${kbit}kbit (${kbps}KB/s)"
    else
        warn "ifb0 不可用，仅设置了出站限速"
    fi

    save_rules

    hr
    ok "端口 ${port} 限速已生效: ${kbps}KB/s (${kbit}kbit)"
}

remove_limit() {
    local port="$1"
    local skip_save="${2:-false}"

    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "无效端口: $port"

    local removed=0

    if tc class show dev "$OUT_IF" 2>/dev/null | grep -q "${ETH_ROOT_HANDLE}${port}\b"; then
        tc filter del dev "$OUT_IF" parent "$ETH_ROOT_HANDLE" prio 1 flower src_port "$port" 2>/dev/null || true
        tc class del dev "$OUT_IF" classid "${ETH_ROOT_HANDLE}${port}" 2>/dev/null || true
        info "已移除 eth0 端口 ${port} 限速"
        removed=1
    fi

    if [[ "$HAS_IFB" -eq 1 ]]; then
        if tc class show dev "$INGRESS_IF" 2>/dev/null | grep -q "${IFB_ROOT_HANDLE}${port}\b"; then
            tc filter del dev "$INGRESS_IF" parent "$IFB_ROOT_HANDLE" prio 1 flower dst_port "$port" 2>/dev/null || true
            tc class del dev "$INGRESS_IF" classid "${IFB_ROOT_HANDLE}${port}" 2>/dev/null || true
            info "已移除 ifb0 端口 ${port} 限速"
            removed=1
        fi
    fi

    if [[ "$removed" -eq 0 ]]; then
        warn "端口 ${port} 未找到限速规则"
    elif [[ "$skip_save" != "true" ]]; then
        save_rules
    fi
}

# ============================================================================
# 规则持久化
# ============================================================================
save_rules() {
    >"${RULES_CONF}"
    while IFS= read -r line; do
        if [[ "$line" =~ class\ htb\ ${ETH_ROOT_HANDLE}([0-9a-fA-F]+)\ .*rate\ ([0-9]+)[Kk]bit ]]; then
            local minor="${BASH_REMATCH[1]}"
            local kbit="${BASH_REMATCH[2]}"
            local port=$((16#${minor}))
            [[ "$port" -eq "$((16#${DEFAULT_CLASS}))" ]] && continue
            echo "${port}|$((kbit / 8))|${minor}|${minor}" >>"${RULES_CONF}"
        fi
    done < <(tc class show dev "$OUT_IF" 2>/dev/null)
}

load_rules() {
    [[ -f "${RULES_CONF}" ]] || return 1
    local loaded=0
    while IFS='|' read -r port kbps _ _; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        [[ "$kbps" =~ ^[0-9]+$ ]] || continue
        add_limit "$port" "$kbps"
        loaded=1
    done <"${RULES_CONF}"
    return $(( loaded == 0 ))
}

# ============================================================================
# 显示函数
# ============================================================================
show_ports() {
    hr
    echo -e "${BOLD}${GREEN}📋 当前监听端口${NC}"
    hr
    printf "  ${BOLD}%-8s %-8s %s${NC}\n" "协议" "端口" "进程"
    hr

    local found=0 line proto ip_port port proc

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        proto="tcp"
        ip_port=$(echo "$line" | awk '{print $5}')
        port="${ip_port##*:}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        proc=$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
        [[ -z "$proc" ]] && proc="-"
        printf "  ${CYAN}%-8s${NC} %-8s %s\n" "$proto" "$port" "$proc"
        found=1
    done < <(ss -tlnp 2>/dev/null | tail -n +2)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        proto="udp"
        ip_port=$(echo "$line" | awk '{print $5}')
        port="${ip_port##*:}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        proc=$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
        [[ -z "$proc" ]] && proc="-"
        printf "  ${CYAN}%-8s${NC} %-8s %s\n" "$proto" "$port" "$proc"
        found=1
    done < <(ss -ulnp 2>/dev/null | tail -n +2)

    if [[ "$found" -eq 0 ]]; then
        echo -e "  ${DIM}无监听端口${NC}"
    fi
    hr
}

show_rules() {
    hr
    echo -e "${BOLD}${GREEN}🔍 当前限速规则${NC}"
    hr

    local found=0

    show_rules_for_dev() {
        local dev="$1" label="$2" handle="$3"
        local classes line minor kbit port kbps
        classes=$(tc class show dev "$dev" 2>/dev/null | grep "htb" | grep -v "${handle}${DEFAULT_CLASS}") || true
        if [[ -z "$classes" ]]; then
            return
        fi
        echo -e "  ${BOLD}${MAGENTA}${label}${NC} (${dev})"
        while IFS= read -r line; do
            if [[ "$line" =~ class\ htb\ ${handle}([0-9a-fA-F]+)\ .*rate\ ([0-9]+)[Kk]bit ]]; then
                minor="${BASH_REMATCH[1]}"
                kbit="${BASH_REMATCH[2]}"
                port=$((16#${minor}))
                kbps=$((kbit / 8))
                printf "    ${CYAN}端口 %-7s${NC} → ${YELLOW}%s kbit${NC} (${YELLOW}%s KB/s${NC})\n" \
                    "$port" "$kbit" "$kbps"
                found=1
            fi
        done <<<"$classes"
    }

    show_rules_for_dev "$OUT_IF" "eth0 出站" "$ETH_ROOT_HANDLE"
    if [[ "$HAS_IFB" -eq 1 ]]; then
        show_rules_for_dev "$INGRESS_IF" "ifb0 入站" "$IFB_ROOT_HANDLE"
    fi

    if [[ "$found" -eq 0 ]]; then
        echo -e "  ${DIM}当前无限速规则${NC}"
    fi
    hr
}

show_status() {
    hr
    echo -e "${BOLD}${GREEN}⚙️ 系统状态${NC}"
    hr
    echo -e "  外网接口:   ${CYAN}${OUT_IF}${NC}"
    if [[ "$HAS_IFB" -eq 1 ]]; then
        echo -e "  ifb0 状态:  ${GREEN}可用 ✓${NC}"
    else
        echo -e "  ifb0 状态:  ${RED}不可用 ✗${NC}"
    fi
    echo -e "  规则文件:   ${CYAN}${RULES_CONF}${NC}"

    local svc_enabled="未安装"
    local svc_active="未运行"
    if command -v systemctl &>/dev/null; then
        if systemctl is-enabled tc-limit.service &>/dev/null 2>&1; then
            svc_enabled="${GREEN}已启用${NC}"
        else
            svc_enabled="${DIM}未启用${NC}"
        fi
        if systemctl is-active tc-limit.service &>/dev/null 2>&1; then
            svc_active="${GREEN}运行中${NC}"
        else
            svc_active="${DIM}未运行${NC}"
        fi
    fi
    echo -e "  开机自启:   ${svc_enabled}"
    echo -e "  服务状态:   ${svc_active}"
    hr
}

# ============================================================================
# 交互菜单
# ============================================================================
menu_add() {
    clear
    hr
    echo -e "${BOLD}${GREEN}⚡ 添加端口限速${NC}"
    hr
    echo

    show_ports
    echo

    local port kbps

    port=$(read_input "请输入端口号" "" "^[0-9]{1,5}$")
    while ((port < 1 || port > 65535)); do
        warn "端口范围: 1-65535"
        port=$(read_input "请输入端口号" "" "^[0-9]{1,5}$")
    done

    kbps=$(read_input "请输入限速速率 (KB/s)" "" "^[0-9]+$")
    while ((kbps < 1)); do
        warn "速率必须 > 0"
        kbps=$(read_input "请输入限速速率 (KB/s)" "" "^[0-9]+$")
    done

    echo
    echo -e "  ${BOLD}待添加限速:${NC}"
    echo -e "    端口: ${CYAN}${port}${NC}"
    echo -e "    速率: ${YELLOW}${kbps} KB/s${NC} = ${YELLOW}$((kbps * 8)) kbit${NC}"
    echo

    if ! confirm "确认添加?"; then
        info "已取消"
        echo
        read -r -s -p "按回车返回菜单..."
        return
    fi

    echo
    add_limit "$port" "$kbps"
    echo
    read -r -s -p "按回车返回菜单..."
}

menu_remove() {
    clear
    hr
    echo -e "${BOLD}${GREEN}🗑️ 删除端口限速${NC}"
    hr
    echo

    show_rules

    local limited_ports=() line minor port
    while IFS= read -r line; do
        if [[ "$line" =~ class\ htb\ ${ETH_ROOT_HANDLE}([0-9a-fA-F]+)\ .*rate\ ([0-9]+)[Kk]bit ]]; then
            minor="${BASH_REMATCH[1]}"
            port=$((16#${minor}))
            [[ "$port" -eq "$((16#${DEFAULT_CLASS}))" ]] && continue
            limited_ports+=("$port")
        fi
    done < <(tc class show dev "$OUT_IF" 2>/dev/null)

    if [[ ${#limited_ports[@]} -eq 0 ]]; then
        echo -e "  ${DIM}没有可删除的限速规则${NC}"
        echo
        read -r -s -p "按回车返回菜单..."
        return
    fi

    echo -e "  已限制端口: ${CYAN}${limited_ports[*]}${NC}"
    echo

    port=$(read_input "请输入要删除的端口号 (输入 q 取消)" "" "^([0-9]{1,5}|q)$")
    [[ "$port" == "q" ]] && { info "已取消"; echo; read -r -s -p "按回车返回菜单..."; return; }
    while ((port < 1 || port > 65535)); do
        port=$(read_input "请输入有效端口号 (输入 q 取消)" "" "^([0-9]{1,5}|q)$")
        [[ "$port" == "q" ]] && { info "已取消"; echo; read -r -s -p "按回车返回菜单..."; return; }
    done

    if ! confirm "确认删除端口 ${port} 的限速规则?"; then
        info "已取消"
        echo
        read -r -s -p "按回车返回菜单..."
        return
    fi

    echo
    remove_limit "$port"
    echo
    read -r -s -p "按回车返回菜单..."
}

menu_install_service() {
    clear
    hr
    echo -e "${BOLD}${GREEN}⚙️ 开机自启管理${NC}"
    hr
    echo

    show_status
    echo

    if ! command -v systemctl &>/dev/null; then
        warn "当前系统未安装 systemd，开机自启功能不可用"
        echo
        read -r -s -p "按回车返回菜单..."
        return
    fi

    echo -e "  ${BOLD}选项:${NC}"
    echo -e "    ${CYAN}[1]${NC} 安装/更新开机自启"
    echo -e "    ${CYAN}[2]${NC} 卸载开机自启"
    echo -e "    ${CYAN}[3]${NC} 查看服务日志"
    echo -e "    ${CYAN}[0]${NC} 返回"
    echo
    local choice
    choice=$(read_input "请选择" "" "^[0-3]$")

    case "$choice" in
    1)
        save_rules
        cat >"${SERVICE_FILE}" <<SERVICEEOF
[Unit]
Description=TC Port Rate Limiter
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT_PATH} load
ExecStop=${SCRIPT_PATH} unload-all

[Install]
WantedBy=multi-user.target
SERVICEEOF
        systemctl daemon-reload
        systemctl enable tc-limit.service 2>/dev/null || warn "systemctl enable 失败"
        ok "开机自启已安装"
        info "规则已保存至 ${RULES_CONF}"
        info "服务文件: ${SERVICE_FILE}"
        echo
        echo "  后续可用命令:"
        echo "    systemctl start tc-limit    立即应用规则"
        echo "    systemctl stop tc-limit     清除所有规则"
        echo "    systemctl status tc-limit   查看状态"
        ;;

    2)
        systemctl disable tc-limit.service 2>/dev/null || warn "未找到已启用的服务"
        systemctl stop tc-limit.service 2>/dev/null || true
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload
        ok "开机自启已卸载"
        ;;

    3)
        echo
        journalctl -u tc-limit.service --no-pager -n 30 2>/dev/null || warn "无法读取日志（服务可能未运行）"
        ;;

    0) echo; read -r -s -p "按回车返回菜单..."; return ;;
    esac

    echo
    read -r -s -p "按回车返回菜单..."
}

# ============================================================================
# 批量操作 (供 systemd 调用)
# ============================================================================
cmd_load() {
    init_all
    if load_rules; then
        ok "规则已从 ${RULES_CONF} 恢复"
    else
        warn "无持久化规则可恢复"
    fi
}

cmd_unload_all() {
    local ports=() line minor port
    while IFS= read -r line; do
        if [[ "$line" =~ class\ htb\ ${ETH_ROOT_HANDLE}([0-9a-fA-F]+) ]]; then
            minor="${BASH_REMATCH[1]}"
            port=$((16#${minor}))
            [[ "$port" -eq "$((16#${DEFAULT_CLASS}))" ]] && continue
            ports+=("$port")
        fi
    done < <(tc class show dev "$OUT_IF" 2>/dev/null)

    for port in "${ports[@]}"; do
        remove_limit "$port" true
    done

    tc qdisc del dev "$OUT_IF" root 2>/dev/null || true
    if [[ "$HAS_IFB" -eq 1 ]]; then
        tc qdisc del dev "$INGRESS_IF" root 2>/dev/null || true
    fi
    >"${RULES_CONF}"
    ok "所有限速规则已清除"
}

# ============================================================================
# 主菜单
# ============================================================================
main_menu() {
    init_all

    while true; do
        clear
        cat <<'BANNER'
╔══════════════════════════════════════════╗
║        🚦 TC 端口限速管理器               ║
║        LXC / NAT 容器专用                ║
╚══════════════════════════════════════════╝
BANNER
        show_status

        echo -e "  ${BOLD}${GREEN}[1]${NC} 📋 查看监听端口"
        echo -e "  ${BOLD}${GREEN}[2]${NC} 🔍 查看限速规则"
        echo -e "  ${BOLD}${GREEN}[3]${NC} ⚡ 添加端口限速"
        echo -e "  ${BOLD}${GREEN}[4]${NC} 🗑️  删除端口限速"
        echo -e "  ${BOLD}${GREEN}[5]${NC} ⚙️  开机自启管理"
        echo -e "  ${BOLD}${RED}[0]${NC} 🚪 退出"
        echo
        local choice
        choice=$(read_input "请输入选项" "" "^[0-5]$")

        case "$choice" in
        1)
            clear
            show_ports
            echo
            read -r -s -p "按回车返回菜单..."
            ;;
        2)
            clear
            show_rules
            echo
            read -r -s -p "按回车返回菜单..."
            ;;
        3) menu_add ;;
        4) menu_remove ;;
        5) menu_install_service ;;
        0)
            echo
            info "再见!"
            exit 0
            ;;
        esac
    done
}

# ============================================================================
# 入口
# ============================================================================
case "${1:-menu}" in
load) cmd_load ;;
unload-all) cmd_unload_all ;;
install)
    init_all
    save_rules
    cat >"${SERVICE_FILE}" <<SERVICEEOF
[Unit]
Description=TC Port Rate Limiter
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT_PATH} load
ExecStop=${SCRIPT_PATH} unload-all

[Install]
WantedBy=multi-user.target
SERVICEEOF
    systemctl daemon-reload
    systemctl enable tc-limit.service
    ok "开机自启已安装 (systemctl enable tc-limit)"
    ;;
uninstall)
    systemctl disable tc-limit.service 2>/dev/null || true
    systemctl stop tc-limit.service 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    ok "开机自启已卸载"
    ;;
status)
    init_all
    show_status
    show_rules
    ;;
menu | *)
    main_menu
    ;;
esac
