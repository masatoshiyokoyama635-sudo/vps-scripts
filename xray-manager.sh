#!/bin/bash
# ============================================
#   Xray 节点管理脚本
#   支持: VLESS+Reality+TCP / Shadowsocks
# ============================================

set -e

# ---- 配置 ----
XRAY_CONF="/usr/local/etc/xray/config.json"
NODES_DB="/usr/local/etc/xray/nodes.txt"
PUBLIC_IP=""

# ---- 颜色 ----
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
C='\033[0;36m'; B='\033[1m';    N='\033[0m'

msg()  { echo -e "${G}[√]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1" >&2; }
err()  { echo -e "${R}[×]${N} $1" >&2; }

# ============================================
#  工具函数
# ============================================

check_deps() {
    local need=()
    command -v jq &>/dev/null      || need+=(jq)
    command -v openssl &>/dev/null || need+=(openssl)
    if [ ${#need[@]} -gt 0 ]; then
        read -p "缺少依赖: ${need[*]}，是否安装? [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] || exit 1
        apt update && apt install -y "${need[@]}"
    fi
    if ! command -v xray &>/dev/null; then
        read -p "未检测到 Xray，是否安装? [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] || exit 1
        bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
    fi
    PUBLIC_IP=$(curl -s ip.sb)
    mkdir -p /usr/local/etc/xray
}

port_used() { ss -tlnp 2>/dev/null | grep -qw ":$1 " && return 0 || return 1; }

read_port() {
    local port
    while true; do
        read -p "输入监听端口: " port
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { warn "端口范围 1-65535"; continue; }
        if port_used "$port"; then
            warn "端口 $port 已被占用"
            continue
        fi
        echo "$port"
        return
    done
}

# ============================================
#  防火墙
# ============================================

open_firewall() {
    local port=$1
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    command -v ufw &>/dev/null && ufw allow "$port"/tcp &>/dev/null
    command -v netfilter-persistent &>/dev/null && netfilter-persistent save &>/dev/null
}

close_firewall() {
    local port=$1
    iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    command -v ufw &>/dev/null && ufw delete allow "$port"/tcp &>/dev/null || true
    command -v netfilter-persistent &>/dev/null && netfilter-persistent save &>/dev/null
}

# ============================================
#  配置管理（nodes.txt 为唯一数据源）
# ============================================

# 从 nodes.txt 重新生成 xray 配置
rebuild_config() {
    local config='{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}'

    if [ ! -f "$NODES_DB" ] || [ ! -s "$NODES_DB" ]; then
        echo "$config" | jq '.' > "$XRAY_CONF"
        return
    fi

    while IFS='|' read -r _type _port _f3 _f4 _f5 _f6 _f7 _f8 _f9; do
        if [ "$_type" = "vless" ]; then
            # vless|port|uuid|flow|sni|privkey|pubkey|shortid|remark
            local inbound=$(jq -n \
                --arg port "$_port" --arg uuid "$_f3" --arg flow "$_f4" \
                --arg sni "$_f5" --arg privkey "$_f6" --arg shortid "$_f8" \
                '{listen:"0.0.0.0",port:($port|tonumber),protocol:"vless",
                  settings:{clients:[{id:$uuid,flow:$flow}],decryption:"none"},
                  streamSettings:{network:"tcp",security:"reality",
                    realitySettings:{dest:("\($sni):443"),serverNames:[$sni],
                      privateKey:$privkey,shortIds:[$shortid]}}}')
            config=$(echo "$config" | jq --argjson ib "$inbound" '.inbounds += [$ib]')

        elif [ "$_type" = "ss" ]; then
            # ss|port|method|password|remark
            local inbound=$(jq -n \
                --arg port "$_port" --arg method "$_f3" --arg password "$_f4" \
                '{listen:"0.0.0.0",port:($port|tonumber),protocol:"shadowsocks",
                  settings:{method:$method,password:$password,network:"tcp,udp"}}')
            config=$(echo "$config" | jq --argjson ib "$inbound" '.inbounds += [$ib]')
        fi
    done < "$NODES_DB"

    echo "$config" | jq '.' > "$XRAY_CONF"
}

restart_xray() {
    systemctl restart xray && msg "Xray 已重启" || err "Xray 重启失败"
}

# ============================================
#  添加 VLESS+Reality 节点
# ============================================

add_vless() {
    echo -e "\n${B}━━━ 添加 VLESS+Reality 节点 ━━━${N}\n"

    local port=$(read_port)

    echo "正在生成密钥..."
    local uuid=$(xray uuid)
    local keys=$(xray x25519)
    local privkey=$(echo "$keys" | grep -i "private" | awk '{print $NF}')
    local pubkey=$(echo "$keys" | grep -i "public" | awk '{print $NF}')
    local shortid=$(openssl rand -hex 8)

    local default_sni="www.sony.com"
    read -p "伪装域名 [回车默认 $default_sni]: " sni
    sni="${sni:-$default_sni}"

    read -p "节点备注 [回车默认 VLESS-$port]: " remark
    remark="${remark:-VLESS-$port}"

    # 写入 nodes.txt
    echo "vless|$port|$uuid|xtls-rprx-vision|$sni|$privkey|$pubkey|$shortid|$remark" >> "$NODES_DB"

    # 重建配置 + 防火墙 + 重启
    rebuild_config
    open_firewall "$port"
    restart_xray

    # 输出信息
    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    msg "节点创建成功！"
    echo -e "  端口:   ${B}$port${N}"
    echo -e "  UUID:   ${B}$uuid${N}"
    echo -e "  SNI:    ${B}$sni${N}"
    echo ""
    echo -e "  客户端链接:"
    echo -e "  ${G}vless://${uuid}@${PUBLIC_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pubkey}&sid=${shortid}&spx=%2F&type=tcp#${remark}${N}"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ============================================
#  添加 Shadowsocks 节点
# ============================================

add_ss() {
    echo -e "\n${B}━━━ 添加 Shadowsocks 节点 ━━━${N}\n"

    local port=$(read_port)

    local default_method="aes-256-gcm"
    read -p "加密方式 [回车默认 $default_method]: " method
    method="${method:-$default_method}"

    local password=$(openssl rand -base64 16 | tr -d '=/+')

    read -p "节点备注 [回车默认 SS-$port]: " remark
    remark="${remark:-SS-$port}"

    # 写入 nodes.txt
    echo "ss|$port|$method|$password|$remark" >> "$NODES_DB"

    # 重建配置 + 防火墙 + 重启
    rebuild_config
    open_firewall "$port"
    restart_xray

    # 生成 SS 链接
    local ss_link=$(printf "%s:%s@%s:%s" "$method" "$password" "$PUBLIC_IP" "$port" | base64 -w0)

    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    msg "节点创建成功！"
    echo -e "  端口:     ${B}$port${N}"
    echo -e "  加密方式: ${B}$method${N}"
    echo -e "  密码:     ${B}$password${N}"
    echo ""
    echo -e "  客户端链接:"
    echo -e "  ${G}ss://${ss_link}#${remark}${N}"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ============================================
#  列出所有节点
# ============================================

list_nodes() {
    if [ ! -f "$NODES_DB" ] || [ ! -s "$NODES_DB" ]; then
        warn "暂无节点，请先添加"
        return
    fi

    echo ""
    echo -e "${B}当前节点列表 (共 $(wc -l < "$NODES_DB") 个)${N}"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"

    local i=1
    while IFS='|' read -r type port f3 f4 f5 f6 f7 f8 f9; do
        if [ "$type" = "vless" ]; then
            echo -e "  ${G}$i${N}. ${B}[VLESS+Reality]${N} $f9"
            echo -e "     端口: $port | SNI: $f5"
            echo -e "     链接: vless://${f3}@${PUBLIC_IP}:${port}?encryption=none&flow=${f4}&security=reality&sni=${f5}&fp=chrome&pbk=${f7}&sid=${f8}&spx=%2F&type=tcp#${f9}"
        elif [ "$type" = "ss" ]; then
            local ss_link=$(printf "%s:%s@%s:%s" "$f3" "$f4" "$PUBLIC_IP" "$port" | base64 -w0)
            echo -e "  ${G}$i${N}. ${B}[Shadowsocks]${N} $f5"
            echo -e "     端口: $port | 加密: $f3"
            echo -e "     链接: ss://${ss_link}#${f5}"
        fi
        ((i++))
    done < "$NODES_DB"

    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ============================================
#  删除节点
# ============================================

delete_node() {
    if [ ! -f "$NODES_DB" ] || [ ! -s "$NODES_DB" ]; then
        warn "暂无节点"
        return
    fi

    list_nodes
    echo ""
    read -p "输入要删除的节点编号: " num

    local total=$(wc -l < "$NODES_DB")
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$total" ]; then
        err "无效编号"
        return
    fi

    local line=$(sed -n "${num}p" "$NODES_DB")
    local port=$(echo "$line" | cut -d'|' -f2)
    local type=$(echo "$line" | cut -d'|' -f1)
    local remark=$(echo "$line" | cut -d'|' -f9)

    echo ""
    warn "即将删除: 端口 $port ($remark)"
    read -p "确认删除? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { warn "已取消"; return; }

    # 从 nodes.txt 删除
    sed -i "${num}d" "$NODES_DB"

    # 重建配置 + 关闭防火墙 + 重启
    rebuild_config
    close_firewall "$port"
    restart_xray
    msg "节点已删除"
}

# ============================================
#  导出所有节点链接
# ============================================

export_links() {
    if [ ! -f "$NODES_DB" ] || [ ! -s "$NODES_DB" ]; then
        warn "暂无节点"
        return
    fi

    echo ""
    echo -e "${B}所有节点链接:${N}"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"

    while IFS='|' read -r type port f3 f4 f5 f6 f7 f8 f9; do
        if [ "$type" = "vless" ]; then
            echo "vless://${f3}@${PUBLIC_IP}:${port}?encryption=none&flow=${f4}&security=reality&sni=${f5}&fp=chrome&pbk=${f7}&sid=${f8}&spx=%2F&type=tcp#${f9}"
        elif [ "$type" = "ss" ]; then
            local ss_link=$(printf "%s:%s@%s:%s" "$f3" "$f4" "$PUBLIC_IP" "$port" | base64 -w0)
            echo "ss://${ss_link}#${f5}"
        fi
    done < "$NODES_DB"

    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ============================================
#  主菜单
# ============================================

show_menu() {
    clear
    echo -e "${C}"
    echo "╔═══════════════════════════════════════╗"
    echo "║       Xray 节点管理脚本               ║"
    echo "║   VLESS+Reality / Shadowsocks         ║"
    echo "╚═══════════════════════════════════════╝"
    echo -e "${N}"
    echo -e "  ${B}1.${N} 添加 VLESS+Reality 节点"
    echo -e "  ${B}2.${N} 添加 Shadowsocks 节点"
    echo -e "  ${B}3.${N} 查看所有节点"
    echo -e "  ${B}4.${N} 删除节点"
    echo -e "  ${B}5.${N} 导出所有链接"
    echo -e "  ${B}0.${N} 退出"
    echo ""
    read -p "请选择 [0-5]: " choice

    case $choice in
        1) add_vless ;;
        2) add_ss ;;
        3) list_nodes ;;
        4) delete_node ;;
        5) export_links ;;
        0) echo -e "\n再见！"; exit 0 ;;
        *) warn "无效选择" ;;
    esac

    echo ""
    read -p "按回车键继续..."
}

# ============================================
#  入口
# ============================================

main() {
    check_deps

    # 如果已有手动配置的节点但没有 nodes.txt，提示用户
    if [ -f "$XRAY_CONF" ] && [ ! -f "$NODES_DB" ]; then
        local inbound_count=$(jq '.inbounds | length' "$XRAY_CONF" 2>/dev/null || echo "0")
        if [ "$inbound_count" -gt 0 ]; then
            warn "检测到现有 xray 配置中有 $inbound_count 个 inbound"
            warn "启动脚本管理前，建议先备份: cp $XRAY_CONF{,.bak}"
            warn "然后清空配置由脚本接管，或手动录入 nodes.txt"
            echo ""
            read -p "是否将现有配置备份并初始化? [y/N] " yn
            if [[ "$yn" =~ ^[Yy]$ ]]; then
                cp "$XRAY_CONF" "${XRAY_CONF}.bak"
                msg "已备份到 ${XRAY_CONF}.bak"
                touch "$NODES_DB"
            fi
        else
            touch "$NODES_DB"
        fi
    fi

    [ ! -f "$NODES_DB" ] && touch "$NODES_DB"

    while true; do
        show_menu
    done
}

main
