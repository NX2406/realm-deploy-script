#!/bin/bash
# ============================================================
#  Realm 一站式管理脚本 v2.0
#  使用方法：sudo bash realm_deploy.sh
# ============================================================

INSTALL_DIR="/opt/realm"
CONFIG_FILE="${INSTALL_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
BINARY="${INSTALL_DIR}/realm"

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------- 基础输出 ----------
info()    { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "  ${RED}✘${RESET}  $*"; }
success() { echo -e "  ${GREEN}${BOLD}✔ 成功：${RESET}$*"; }
step()    { echo -e "\n  ${CYAN}▶${RESET}  $*"; }
divider() { echo -e "  ${CYAN}──────────────────────────────────────────${RESET}"; }

title() {
    echo ""
    echo -e "  ${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
    printf   "  ${BOLD}${CYAN}║  %-40s║${RESET}\n" "$*"
    echo -e "  ${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
    echo ""
}

press_any_key() {
    echo ""
    read -rp "  按 Enter 键返回主菜单..." _KEY < /dev/tty
}

# ---------- 校验函数 ----------
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

# 使用 Python 做统一校验：
# 1) 支持 IPv4 / IPv6（含压缩写法）
# 2) 支持域名（含多级/二级域名、punycode、末尾点）
# 3) 字面 IP 必须是公网地址（拒绝内网/回环/链路本地/保留地址）
validate_host() {
    local h="$1"
    [[ -n "$h" && "$h" != *' '* ]] || return 1

    python3 - "$h" <<'PYEOF' >/dev/null 2>&1
import re
import sys
import ipaddress

host = sys.argv[1].strip()

if host.endswith('.'):
    host = host[:-1]

# IP: 仅允许公网
try:
    ip = ipaddress.ip_address(host)
    if ip.is_global:
        sys.exit(0)
    sys.exit(1)
except ValueError:
    pass

# 域名: 支持 IDN -> punycode
try:
    ascii_host = host.encode('idna').decode('ascii')
except Exception:
    sys.exit(1)

if len(ascii_host) == 0 or len(ascii_host) > 253:
    sys.exit(1)

labels = ascii_host.split('.')
if len(labels) < 2:
    sys.exit(1)

label_re = re.compile(r'^[A-Za-z0-9-]{1,63}$')
for lb in labels:
    if not label_re.match(lb):
        sys.exit(1)
    if lb.startswith('-') or lb.endswith('-'):
        sys.exit(1)

if labels[-1].isdigit():
    sys.exit(1)

sys.exit(0)
PYEOF
}

# ---------- 检查 root 权限 ----------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo ""
        error "请使用 root 权限运行此脚本："
        echo -e "       sudo bash $0"
        echo ""
        exit 1
    fi
}

# ---------- 检查是否已安装 ----------
check_installed() {
    if [[ ! -f "$BINARY" ]]; then
        error "Realm 未安装，请先选择菜单项 [1] 进行安装"
        press_any_key
        return 1
    fi
}

# ---------- 获取服务状态（用于主菜单显示） ----------
get_status() {
    if systemctl is-active --quiet realm 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    elif systemctl is-enabled --quiet realm 2>/dev/null; then
        echo -e "${YELLOW}● 已停止${RESET}"
    elif [[ -f "$BINARY" ]]; then
        echo -e "${YELLOW}● 已安装（服务未注册）${RESET}"
    else
        echo -e "${RED}● 未安装${RESET}"
    fi
}

# ---------- 统计规则数量 ----------
count_rules() {
    [[ -f "$CONFIG_FILE" ]] || { echo 0; return; }
    grep -c '^\[\[endpoints\]\]' "$CONFIG_FILE" 2>/dev/null || echo 0
}

# ---------- 重启服务 ----------
reload_and_restart() {
    if systemctl is-enabled --quiet realm 2>/dev/null; then
        step "重载并重启 Realm 服务..."
        systemctl daemon-reload
        systemctl restart realm
        sleep 1
        if systemctl is-active --quiet realm; then
            info "服务运行正常"
        else
            warn "服务状态异常，请检查："
            systemctl status realm --no-pager
        fi
    fi
}

# ---------- 写入 systemd 服务文件 ----------
write_service_file() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Network Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/realm -c ${INSTALL_DIR}/config.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

# ============================================================
#  交互式收集转发规则（追加到 CONFIG_FILE）
# ============================================================
add_rules_interactive() {
    local added=0
    while true; do
        echo ""
        local rule_num=$(( added + 1 ))
        echo -e "  ${YELLOW}--- 转发规则 #${rule_num} ---${RESET}"

        local lport rhost rport

        # 监听端口
        while true; do
            read -rp "  本机监听端口 [1-65535]：" lport < /dev/tty
            validate_port "$lport" && break
            warn "端口无效，请输入 1～65535 之间的整数"
        done

        # 远端地址
        while true; do
            read -rp "  远端 IP 或域名：" rhost < /dev/tty
            validate_host "$rhost" && break
            warn "地址无效：仅支持合法公网 IPv4/IPv6 或域名（含二级/多级域名，例如 a.b.example.com）"
        done

        # 远端端口
        while true; do
            read -rp "  远端端口 [1-65535]：" rport < /dev/tty
            validate_port "$rport" && break
            warn "端口无效，请输入 1～65535 之间的整数"
        done

        # 追加到配置文件
        {
            echo ""
            echo "[[endpoints]]"
            echo "listen = \"0.0.0.0:${lport}\""
            echo "remote = \"${rhost}:${rport}\""
        } >> "$CONFIG_FILE"

        added=$(( added + 1 ))
        info "已添加：本机 0.0.0.0:${lport}  →  ${rhost}:${rport}"

        echo ""
        read -rp "  继续添加另一条规则？[y/N] " MORE < /dev/tty
        [[ "$MORE" =~ ^[Yy]$ ]] || break
    done
    echo ""
    info "共添加 ${added} 条转发规则"
}

# ============================================================
#  列出并显示所有规则（带序号）
#  返回值：0=有规则  1=无规则
# ============================================================
list_rules_display() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "配置文件不存在，请先安装服务"
        return 1
    fi

    local total
    total=$(count_rules)
    if (( total == 0 )); then
        warn "当前没有任何转发规则"
        return 1
    fi

    echo ""
    echo -e "  ${BOLD}序号   本机监听地址               →  远端地址${RESET}"
    divider

    python3 - "$CONFIG_FILE" <<'PYEOF'
import re, sys

with open(sys.argv[1]) as f:
    content = f.read()

blocks = re.findall(r'\[\[endpoints\]\][^\[]*', content)
for i, b in enumerate(blocks, 1):
    l = re.search(r'listen\s*=\s*"([^"]+)"', b)
    r = re.search(r'remote\s*=\s*"([^"]+)"', b)
    if l and r:
        print(f"  [{i}]    {l.group(1):<26} →  {r.group(1)}")
PYEOF
    echo ""
    return 0
}

# ============================================================
#  主菜单
# ============================================================
show_menu() {
    clear
    echo ""
    echo -e "  ${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "  ${BOLD}${CYAN}║        Realm 转发管理工具  v2.0              ║${RESET}"
    echo -e "  ${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  服务状态：$(get_status)"
    echo -e "  转发规则：${BOLD}$(count_rules) 条${RESET}"
    echo ""
    divider
    echo -e "  ${BOLD}1.${RESET}  安装 Realm 服务"
    echo -e "  ${BOLD}2.${RESET}  添加转发规则"
    echo -e "  ${BOLD}3.${RESET}  删除转发规则"
    echo -e "  ${BOLD}4.${RESET}  修改转发规则"
    echo -e "  ${BOLD}5.${RESET}  彻底卸载环境"
    echo -e "  ${BOLD}0.${RESET}  退出"
    divider
    echo ""
}

# ============================================================
#  功能 1：安装 Realm 服务
# ============================================================
do_install() {
    title "安装 Realm 服务"

    # 已安装则询问是否覆盖
    if [[ -f "$BINARY" ]]; then
        local ver
        ver=$("$BINARY" --version 2>/dev/null || echo "未知")
        warn "检测到已安装的 Realm（版本：${ver}）"
        read -rp "  是否重新下载安装？[y/N] " CONFIRM < /dev/tty
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { press_any_key; return; }
    fi

    # 1. 系统更新
    step "系统更新 (apt update)..."
    apt update -y

    # 2. 创建目录
    step "创建安装目录 ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"

    # 3. 检测 CPU 架构并下载
    local arch arch_name
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch_name="x86_64-unknown-linux-gnu" ;;
        aarch64) arch_name="aarch64-unknown-linux-gnu" ;;
        armv7l)  arch_name="armv7-unknown-linux-gnueabihf" ;;
        *)       error "不支持的 CPU 架构：${arch}，请手动下载"; press_any_key; return 1 ;;
    esac

    local download_url="https://github.com/zhboner/realm/releases/latest/download/realm-${arch_name}.tar.gz"
    step "下载 Realm（架构：${arch_name}）..."
    info "下载地址：${download_url}"

    if ! wget -q --show-progress -O "${INSTALL_DIR}/realm.tar.gz" "$download_url"; then
        error "下载失败，请检查网络连接"
        press_any_key
        return 1
    fi

    # 4. 解压 & 清理
    step "解压..."
    tar -zxf "${INSTALL_DIR}/realm.tar.gz" -C "$INSTALL_DIR"
    rm -f "${INSTALL_DIR}/realm.tar.gz"

    if [[ ! -f "${INSTALL_DIR}/realm" ]]; then
        error "解压后未找到 realm 可执行文件"
        press_any_key
        return 1
    fi
    chmod +x "${INSTALL_DIR}/realm"

    # 移交权限（如果是 sudo 调用）
    local real_user="${SUDO_USER:-}"
    if [[ -n "$real_user" ]] && id "$real_user" &>/dev/null; then
        chown -R "${real_user}:${real_user}" "$INSTALL_DIR"
        info "目录权限已移交给用户 ${real_user}"
    fi

    # 5. 生成基础配置文件（如不存在）
    if [[ ! -f "$CONFIG_FILE" ]]; then
        step "生成基础配置文件..."
        cat > "$CONFIG_FILE" <<'EOF'
[network]
no_tcp_delay = true
keep_alive = 30
EOF
    else
        info "配置文件已存在，保留原有转发规则"
    fi

    # 6. 交互式添加转发规则
    step "配置转发规则..."
    add_rules_interactive

    # 7. 注册 systemd 服务
    step "注册 systemd 服务..."
    write_service_file
    systemctl daemon-reload
    systemctl enable realm
    systemctl restart realm
    sleep 1

    echo ""
    if systemctl is-active --quiet realm; then
        success "Realm 安装并启动成功！"
    else
        warn "服务启动失败，请检查以下信息："
        systemctl status realm --no-pager
    fi

    press_any_key
}

# ============================================================
#  功能 2：添加转发规则
# ============================================================
do_add() {
    title "添加转发规则"
    check_installed || return

    # 显示当前已有规则
    local total
    total=$(count_rules)
    if (( total > 0 )); then
        info "当前已有 ${total} 条规则："
        list_rules_display
    fi

    add_rules_interactive
    reload_and_restart
    press_any_key
}

# ============================================================
#  功能 3：删除转发规则
# ============================================================
do_delete() {
    title "删除转发规则"
    check_installed || return
    list_rules_display || { press_any_key; return; }

    local total idx
    total=$(count_rules)

    while true; do
        read -rp "  请输入要删除的规则序号 [1-${total}]（输入 0 取消）：" idx < /dev/tty
        [[ "$idx" == "0" ]] && return
        [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= total )) && break
        warn "序号无效，请重新输入"
    done

    # 显示将要删除的规则详情
    local rule_info
    rule_info=$(python3 - "$CONFIG_FILE" "$idx" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
idx = int(sys.argv[2])
blocks = re.findall(r'\[\[endpoints\]\][^\[]*', content)
if 1 <= idx <= len(blocks):
    b = blocks[idx - 1]
    l = re.search(r'listen\s*=\s*"([^"]+)"', b)
    r = re.search(r'remote\s*=\s*"([^"]+)"', b)
    if l and r:
        print(f"{l.group(1)} → {r.group(1)}")
PYEOF
)

    warn "即将删除规则 [#${idx}]：${rule_info}"
    read -rp "  确认删除？[y/N] " CONFIRM < /dev/tty
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "已取消"
        press_any_key
        return
    fi

    # Python 执行删除操作
    python3 - "$CONFIG_FILE" "$idx" <<'PYEOF'
import re, sys

config_file  = sys.argv[1]
target_idx   = int(sys.argv[2]) - 1   # 转为 0-based

with open(config_file) as f:
    content = f.read()

# 提取 [network] 等头部（第一个 [[endpoints]] 之前的内容）
header = re.match(r'(.*?)(?=\[\[endpoints\]\])', content, re.DOTALL)
header = header.group(1).rstrip('\n') if header else content.rstrip('\n')

# 提取所有 [[endpoints]] 块
blocks = re.findall(r'\[\[endpoints\]\][^\[]*', content)
del blocks[target_idx]

# 重新拼接
new_content = header + '\n'
for b in blocks:
    new_content += '\n' + b.strip('\n') + '\n'

with open(config_file, 'w') as f:
    f.write(new_content)
PYEOF

    success "规则 [#${idx}]（${rule_info}）已删除"
    reload_and_restart
    press_any_key
}

# ============================================================
#  功能 4：修改转发规则
# ============================================================
do_modify() {
    title "修改转发规则"
    check_installed || return
    list_rules_display || { press_any_key; return; }

    local total idx
    total=$(count_rules)

    while true; do
        read -rp "  请输入要修改的规则序号 [1-${total}]（输入 0 取消）：" idx < /dev/tty
        [[ "$idx" == "0" ]] && return
        [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= total )) && break
        warn "序号无效，请重新输入"
    done

    # 读取当前值
    local old_info
    old_info=$(python3 - "$CONFIG_FILE" "$idx" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
idx = int(sys.argv[2])
blocks = re.findall(r'\[\[endpoints\]\][^\[]*', content)
if 1 <= idx <= len(blocks):
    b = blocks[idx - 1]
    l = re.search(r'listen\s*=\s*"(?:[^"]*:)?(\d+)"', b)
    r = re.search(r'remote\s*=\s*"([^":]+):(\d+)"', b)
    if l and r:
        print(f"{l.group(1)}|{r.group(1)}|{r.group(2)}")
PYEOF
)

    local old_lport old_rhost old_rport
    IFS='|' read -r old_lport old_rhost old_rport <<< "$old_info"

    echo ""
    echo -e "  当前配置：本机 ${BOLD}0.0.0.0:${old_lport}${RESET}  →  ${BOLD}${old_rhost}:${old_rport}${RESET}"
    echo -e "  ${YELLOW}（直接回车保留当前值）${RESET}"
    echo ""

    local new_lport new_rhost new_rport

    # 新监听端口
    while true; do
        read -rp "  新监听端口 [当前：${old_lport}]：" new_lport < /dev/tty
        [[ -z "$new_lport" ]] && new_lport="$old_lport"
        validate_port "$new_lport" && break
        warn "端口无效，请重新输入"
    done

    # 新远端地址
    while true; do
        read -rp "  新远端 IP/域名 [当前：${old_rhost}]：" new_rhost < /dev/tty
        [[ -z "$new_rhost" ]] && new_rhost="$old_rhost"
        validate_host "$new_rhost" && break
        warn "地址无效：仅支持合法公网 IPv4/IPv6 或域名（含二级/多级域名，例如 a.b.example.com）"
    done

    # 新远端端口
    while true; do
        read -rp "  新远端端口 [当前：${old_rport}]：" new_rport < /dev/tty
        [[ -z "$new_rport" ]] && new_rport="$old_rport"
        validate_port "$new_rport" && break
        warn "端口无效，请重新输入"
    done

    # Python 执行修改操作
    python3 - "$CONFIG_FILE" "$idx" "0.0.0.0:${new_lport}" "${new_rhost}:${new_rport}" <<'PYEOF'
import re, sys

config_file = sys.argv[1]
target_idx  = int(sys.argv[2]) - 1   # 0-based
new_listen  = sys.argv[3]
new_remote  = sys.argv[4]

with open(config_file) as f:
    content = f.read()

header = re.match(r'(.*?)(?=\[\[endpoints\]\])', content, re.DOTALL)
header = header.group(1).rstrip('\n') if header else content.rstrip('\n')

blocks = re.findall(r'\[\[endpoints\]\][^\[]*', content)

def patch_block(block, listen, remote):
    block = re.sub(r'listen\s*=\s*"[^"]+"', f'listen = "{listen}"', block)
    block = re.sub(r'remote\s*=\s*"[^"]+"', f'remote = "{remote}"', block)
    return block

blocks[target_idx] = patch_block(blocks[target_idx], new_listen, new_remote)

new_content = header + '\n'
for b in blocks:
    new_content += '\n' + b.strip('\n') + '\n'

with open(config_file, 'w') as f:
    f.write(new_content)
PYEOF

    success "规则 [#${idx}] 已更新：本机 0.0.0.0:${new_lport}  →  ${new_rhost}:${new_rport}"
    reload_and_restart
    press_any_key
}

# ============================================================
#  功能 5：彻底卸载环境
# ============================================================
do_uninstall() {
    title "彻底卸载 Realm 环境"

    echo -e "  ${RED}此操作将执行以下动作：${RESET}"
    echo -e "    · 停止并禁用 realm 系统服务"
    echo -e "    · 删除服务文件：${SERVICE_FILE}"
    echo -e "    · 删除安装目录及所有配置：${INSTALL_DIR}"
    echo ""
    read -rp "  确认彻底卸载？[y/N] " CONFIRM < /dev/tty
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "已取消"
        press_any_key
        return
    fi

    step "停止并禁用服务..."
    systemctl stop realm   2>/dev/null || true
    systemctl disable realm 2>/dev/null || true

    step "删除服务文件..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    step "删除安装目录 ${INSTALL_DIR}..."
    rm -rf "$INSTALL_DIR"

    echo ""
    success "Realm 已彻底卸载，环境已清理干净"
    press_any_key
}

# ============================================================
#  主程序入口
# ============================================================
check_root

while true; do
    show_menu
    read -rp "  请选择功能 [0-5]：" CHOICE < /dev/tty
    echo ""
    case "$CHOICE" in
        1) do_install   ;;
        2) do_add       ;;
        3) do_delete    ;;
        4) do_modify    ;;
        5) do_uninstall ;;
        0) echo -e "  再见！\n"; exit 0 ;;
        *) warn "无效选项，请输入 0～5"; sleep 1 ;;
    esac
done
