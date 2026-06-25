#!/usr/bin/env bash
# ============================================
#   Xray 节点管理脚本 (多系统兼容版)
#   支持: Ubuntu/Debian, Alpine, CentOS/Rocky
#   支持: VLESS+Reality+TCP / Shadowsocks
#   支持: NAT 小鸡
#   支持: BBR 加速
# ============================================

# ---- 配置 ----
XRAY_CONF="/usr/local/etc/xray/config.json"
NODES_DB="/usr/local/etc/xray/nodes.txt"
PUBLIC_IP=""
PUBLIC_IP6=""
NAT_MODE=false
EXTERNAL_IP=""
BLOCKED_PORTS="22 53 80 443 445 993 995 3389 5900 8080 8443 8888"

# 系统检测变量（由 detect_os 填充）
PKG_MANAGER=""
SERVICE_CMD=""       # systemctl / rc-service
SVC_TYPE=""          # systemd / openrc

# ---- 颜色 ----
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
C='\033[0;36m'; B='\033[1m';    N='\033[0m'

msg()  { echo -e "${G}[√]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1" >&2; }
err()  { echo -e "${R}[×]${N} $1" >&2; }

# ============================================
#  系统检测
# ============================================

detect_os() {
    # 检测包管理器
    if command -v apt &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    else
        err "不支持的系统，未找到包管理器 (apt/apk/dnf/yum)"
        exit 1
    fi
    msg "包管理器: $PKG_MANAGER"

    # 检测服务管理
    if command -v systemctl &>/dev/null; then
        SVC_TYPE="systemd"
        SERVICE_CMD="systemctl"
    elif command -v rc-service &>/dev/null; then
        SVC_TYPE="openrc"
        SERVICE_CMD="rc-service"
    else
        SVC_TYPE="raw"
        SERVICE_CMD=""
        warn "未检测到服务管理器 (systemd/openrc)，将使用手动管理"
    fi
    msg "服务管理: ${SVC_TYPE}"

    # 检测公网 IP（IPv4 / IPv6 分别检测）
    PUBLIC_IP=$(curl -s --connect-timeout 5 -4 api.ipify.org 2>/dev/null || \
                curl -s --connect-timeout 5 -4 ipv4.icanhazip.com 2>/dev/null)
    if [ -n "$PUBLIC_IP" ]; then
        msg "公网 IPv4: $PUBLIC_IP"
    else
        warn "未检测到公网 IPv4"
    fi

    PUBLIC_IP6=$(curl -s --connect-timeout 5 -6 api6.ipify.org 2>/dev/null || \
                 curl -s --connect-timeout 5 -6 ipv6.icanhazip.com 2>/dev/null)
    if [ -n "$PUBLIC_IP6" ]; then
        msg "公网 IPv6: $PUBLIC_IP6"
    else
        warn "未检测到公网 IPv6"
    fi

    if [ -z "$PUBLIC_IP" ] && [ -z "$PUBLIC_IP6" ]; then
        NAT_MODE=true
        warn "未检测到公网 IP，进入 NAT 模式"
    fi
}

# ============================================
#  依赖安装
# ============================================

pkg_install() {
    case "$PKG_MANAGER" in
        apt) apt update && apt install -y "$@" ;;
        apk) apk add --no-cache "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
    esac
}

check_deps() {
    local need=()

    # Alpine 需要先装 bash
    if [ "$PKG_MANAGER" = "apk" ] && ! command -v bash &>/dev/null; then
        msg "Alpine: 安装 bash..."
        apk add --no-cache bash
    fi

    command -v jq &>/dev/null      || need+=(jq)
    command -v openssl &>/dev/null || need+=(openssl)

    if [ ${#need[@]} -gt 0 ]; then
        read -p "缺少依赖: ${need[*]}，是否安装? [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] || exit 1
        pkg_install "${need[@]}"
    fi

    if ! command -v xray &>/dev/null; then
        read -p "未检测到 Xray，是否安装? [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] || exit 1
        bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
        # 安装后验证二进制是否存在（官方脚本在 Alpine 上可能不装二进制）
        if ! command -v xray &>/dev/null; then
            warn "官方安装脚本未成功部署二进制，尝试手动安装..."
            mkdir -p /usr/local/bin /usr/local/etc/xray
            local arch=""
            case "$(uname -m)" in
                x86_64)  arch="64" ;;
                aarch64) arch="arm64-v8a" ;;
                armv7l)  arch="arm32-v7a" ;;
                *)       arch="64" ;;
            esac
            curl -L "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip" -o /tmp/xray.zip
            pkg_install unzip &>/dev/null; unzip -o /tmp/xray.zip -d /tmp/xray
            cp /tmp/xray/xray /usr/local/bin/xray && chmod +x /usr/local/bin/xray
            rm -rf /tmp/xray /tmp/xray.zip
        fi
        if ! command -v xray &>/dev/null; then
            err "Xray 安装失败，请手动安装后重试"
            exit 1
        fi
        setup_xray_service
    fi

    mkdir -p /usr/local/etc/xray
}

# ============================================
#  Xray 服务管理（多系统适配）
# ============================================

setup_xray_service() {
    if [ "$SVC_TYPE" = "openrc" ]; then
        # Alpine / OpenRC: 创建 init.d 脚本
        if [ ! -f /etc/init.d/xray ]; then
            msg "创建 OpenRC 服务..."
            printf '#!/sbin/openrc-run\n\ncommand="/usr/local/bin/xray"\ncommand_args="run -config /usr/local/etc/xray/config.json"\ncommand_background=true\npidfile="/run/xray.pid"\n' > /etc/init.d/xray
            chmod +x /etc/init.d/xray
            rc-update add xray default 2>/dev/null
        fi
    fi
    # systemd: xray 安装脚本已自动创建 service，不需要额外处理
}

svc_restart() {
    case "$SVC_TYPE" in
        systemd) systemctl restart xray ;;
        openrc)  rc-service xray restart ;;
        *)       pkill xray 2>/dev/null; sleep 1; xray run -config "$XRAY_CONF" &>/dev/null & ;;
    esac
}

svc_stop() {
    case "$SVC_TYPE" in
        systemd) systemctl stop xray 2>/dev/null ;;
        openrc)  rc-service xray stop 2>/dev/null ;;
        *)       pkill xray 2>/dev/null ;;
    esac
}

svc_disable() {
    case "$SVC_TYPE" in
        systemd) systemctl disable xray 2>/dev/null ;;
        openrc)  rc-update del xray default 2>/dev/null ;;
    esac
}

restart_xray() {
    svc_restart && msg "Xray 已重启" || err "Xray 重启失败"
}

# ============================================
#  工具函数
# ============================================

port_used() { ss -tlnp 2>/dev/null | grep -qw ":$1 " && return 0 || return 1; }

# base64 兼容（Alpine 不支持 -w0）
b64_encode() { base64 | tr -d '\n'; }

# IPv6 地址在 URL 中需要加方括号
fmt_host() {
    local ip="$1" port="$2"
    if echo "$ip" | grep -q ':'; then
        echo "[${ip}]:${port}"
    else
        echo "${ip}:${port}"
    fi
}

# 生成随机安全端口
random_port() {
    local port
    while true; do
        port=$((RANDOM % 50001 + 10000))
        local blocked=false
        for bp in $BLOCKED_PORTS; do
            [ "$port" = "$bp" ] && blocked=true && break
        done
        $blocked && continue
        port_used "$port" && continue
        echo "$port"
        return
    done
}

read_port() {
    local port default_port
    default_port=$(random_port)
    while true; do
        read -p "监听端口 [回车随机 $default_port]: " port
        port="${port:-$default_port}"
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { warn "端口范围 1-65535"; continue; }
        for bp in $BLOCKED_PORTS; do
            if [ "$port" = "$bp" ]; then
                warn "端口 $port 是常用服务端口，建议换一个"
                read -p "仍然使用? [y/N] " force
                [[ "$force" =~ ^[Yy]$ ]] || { continue 2; }
                break
            fi
        done
        if port_used "$port"; then
            warn "端口 $port 已被占用"
            continue
        fi
        echo "$port"
        return
    done
}

# NAT 模式下读取外部 IP 和端口
read_nat_info() {
    if [ "$NAT_MODE" = true ]; then
        echo ""
        warn "NAT 模式：需要填写外部映射信息"
        read -p "外部 IP (服务商提供的公网 IP): " ext_ip
        read -p "外部端口 (服务商面板映射的外部端口): " ext_port
        echo "$ext_ip|$ext_port"
    else
        echo "|"
    fi
}

# IP 版本选择（双栈时让用户选择）
# 返回格式: ipver|link_ip|listen_addr
choose_ip() {
    if [ -n "$PUBLIC_IP" ] && [ -n "$PUBLIC_IP6" ]; then
        echo -e "\n  ${B}检测到双栈 IP:${N}" >&2
        echo -e "  ${G}1.${N} IPv4: $PUBLIC_IP" >&2
        echo -e "  ${G}2.${N} IPv6: $PUBLIC_IP6" >&2
        echo "" >&2
        read -p "选择 IP 版本 [1=IPv4 / 2=IPv6]: " ip_choice
        case "$ip_choice" in
            2) echo "6|${PUBLIC_IP6}|::" ;;
            *) echo "4|${PUBLIC_IP}|0.0.0.0" ;;
        esac
    elif [ -n "$PUBLIC_IP6" ]; then
        echo -e "${G}[√]${N} 仅检测到 IPv6: $PUBLIC_IP6" >&2
        echo "6|${PUBLIC_IP6}|::"
    elif [ -n "$PUBLIC_IP" ]; then
        echo -e "${G}[√]${N} 仅检测到 IPv4: $PUBLIC_IP" >&2
        echo "4|${PUBLIC_IP}|0.0.0.0"
    else
        NAT_MODE=true
        echo "4||0.0.0.0"
    fi
}

# ============================================
#  防火墙（多系统适配）
# ============================================

open_firewall() {
    local port=$1

    # firewalld (CentOS/Rocky)
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --add-port="$port"/tcp --permanent 2>/dev/null && \
            firewall-cmd --reload 2>/dev/null
        return
    fi

    # iptables (Ubuntu/Debian/Alpine)
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        command -v netfilter-persistent &>/dev/null && netfilter-persistent save &>/dev/null
        return
    fi

    # ufw
    command -v ufw &>/dev/null && ufw allow "$port"/tcp &>/dev/null
}

close_firewall() {
    local port=$1

    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --remove-port="$port"/tcp --permanent 2>/dev/null && \
            firewall-cmd --reload 2>/dev/null
        return
    fi

    if command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        command -v netfilter-persistent &>/dev/null && netfilter-persistent save &>/dev/null
        return
    fi

    command -v ufw &>/dev/null && ufw delete allow "$port"/tcp &>/dev/null || true
}

# ============================================
#  配置管理（nodes.txt 为唯一数据源）
# ============================================

# nodes.txt 格式:
#   vless|port|uuid|flow|sni|privkey|pubkey|shortid|remark|ipver|ext_ip|ext_port
#   ss|port|method|password|remark|ipver|ext_ip|ext_port

rebuild_config() {
    if [ ! -f "$NODES_DB" ] || [ ! -s "$NODES_DB" ]; then
        echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}' | jq '.' > "$XRAY_CONF"
        return
    fi

    local config='{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[],"routing":{"domainStrategy":"AsIs","rules":[]}}'
    local v4_tags="[]" v6_tags="[]"

    while IFS='|' read -r _type _port _f3 _f4 _f5 _f6 _f7 _f8 _f9 _f10 _f11 _f12; do
        [ -z "$_type" ] && continue
        local _listen="0.0.0.0" _ipver="4" _tag=""

        if [ "$_type" = "vless" ]; then
            # 新格式: f10=ipver(4/6), f11=ext_ip, f12=ext_port
            # 旧格式: f10=ext_ip, f11=ext_port, 无 ipver
            if [ "$_f10" = "4" ] || [ "$_f10" = "6" ]; then
                _ipver="$_f10"
                [ "$_ipver" = "6" ] && _listen="::"
            fi
            _tag="v${_ipver}-${_port}"
            local inbound=$(jq -n \
                --arg tag "$_tag" --arg listen "$_listen" \
                --arg port "$_port" --arg uuid "$_f3" --arg flow "$_f4" \
                --arg sni "$_f5" --arg privkey "$_f6" --arg shortid "$_f8" \
                '{tag:$tag,listen:$listen,port:($port|tonumber),protocol:"vless",
                  settings:{clients:[{id:$uuid,flow:$flow}],decryption:"none"},
                  streamSettings:{network:"tcp",security:"reality",
                    realitySettings:{dest:("\($sni):443"),serverNames:[$sni],
                      privateKey:$privkey,shortIds:[$shortid]}}}')
            config=$(echo "$config" | jq --argjson ib "$inbound" '.inbounds += [$ib]')

        elif [ "$_type" = "ss" ]; then
            # 新格式: f6=ipver(4/6), f7=ext_ip, f8=ext_port
            # 旧格式: f6=ext_ip, f7=ext_port, 无 ipver
            if [ "$_f6" = "4" ] || [ "$_f6" = "6" ]; then
                _ipver="$_f6"
                [ "$_ipver" = "6" ] && _listen="::"
            fi
            _tag="v${_ipver}-${_port}"
            local inbound=$(jq -n \
                --arg tag "$_tag" --arg listen "$_listen" \
                --arg port "$_port" --arg method "$_f3" --arg password "$_f4" \
                '{tag:$tag,listen:$listen,port:($port|tonumber),protocol:"shadowsocks",
                  settings:{method:$method,password:$password,network:"tcp,udp"}}')
            config=$(echo "$config" | jq --argjson ib "$inbound" '.inbounds += [$ib]')
        else
            continue
        fi

        if [ "$_ipver" = "6" ]; then
            v6_tags=$(echo "$v6_tags" | jq --arg t "$_tag" '. += [$t]')
        else
            v4_tags=$(echo "$v4_tags" | jq --arg t "$_tag" '. += [$t]')
        fi
    done < "$NODES_DB"

    # 构建 outbound：用 sendThrough 绑定出口 IP，强制走对应 IP 版本
    # 仅当公网 IP 存在于本机网卡时才使用 sendThrough（NAT/容器环境可能无此 IP）
    local v4_count=$(echo "$v4_tags" | jq 'length')
    local v6_count=$(echo "$v6_tags" | jq 'length')

    if [ "$v4_count" -gt 0 ] && [ -n "$PUBLIC_IP" ]; then
        if ip addr show 2>/dev/null | grep -qw "$PUBLIC_IP"; then
            config=$(echo "$config" | jq --arg ip "$PUBLIC_IP" \
                '.outbounds += [{"tag":"out-v4","protocol":"freedom","sendThrough":$ip}]')
        else
            config=$(echo "$config" | jq \
                '.outbounds += [{"tag":"out-v4","protocol":"freedom"}]')
        fi
        config=$(echo "$config" | jq --argjson tags "$v4_tags" \
            '.routing.rules += [{"type":"field","inboundTag":$tags,"outboundTag":"out-v4"}]')
    fi
    if [ "$v6_count" -gt 0 ] && [ -n "$PUBLIC_IP6" ]; then
        if ip addr show 2>/dev/null | grep -qw "$PUBLIC_IP6"; then
            config=$(echo "$config" | jq --arg ip "$PUBLIC_IP6" \
                '.outbounds += [{"tag":"out-v6","protocol":"freedom","sendThrough":$ip}]')
        else
            config=$(echo "$config" | jq \
                '.outbounds += [{"tag":"out-v6","protocol":"freedom"}]')
        fi
        config=$(echo "$config" | jq --argjson tags "$v6_tags" \
            '.routing.rules += [{"type":"field","inboundTag":$tags,"outboundTag":"out-v6"}]')
    fi

    # 兜底：如果没有匹配到任何 outbound（NAT 模式等），加默认 freedom
    local ob_count=$(echo "$config" | jq '.outbounds | length')
    if [ "$ob_count" -eq 0 ]; then
        config=$(echo "$config" | jq '.outbounds += [{"protocol":"freedom"}]')
    fi

    echo "$config" | jq '.' > "$XRAY_CONF"
}

# ============================================
#  添加 VLESS+Reality 节点
# ============================================

add_vless() {
    echo -e "\n${B}━━━ 添加 VLESS+Reality 节点 ━━━${N}\n"

    # 选择 IP 版本
    local ip_info=$(choose_ip)
    local ipver=$(echo "$ip_info" | cut -d'|' -f1)
    local default_ip=$(echo "$ip_info" | cut -d'|' -f2)

    local port=$(read_port)

    echo "正在生成密钥..."
    local uuid=$(xray uuid)
    local keys=$(xray x25519)
    local privkey=$(echo "$keys" | grep -i "private" | awk '{print $NF}')
    local pubkey=$(echo "$keys" | grep -i "public" | awk '{print $NF}')
    local shortid=$(openssl rand -hex 8)
    # 校验密钥是否生成成功
    if [ -z "$uuid" ] || [ -z "$privkey" ] || [ -z "$pubkey" ]; then
        err "密钥生成失败，请确认 xray 已正确安装: xray version"
        return 1
    fi

    local default_sni="www.sony.com"
    read -p "伪装域名 [回车默认 $default_sni]: " sni
    sni="${sni:-$default_sni}"

    read -p "节点备注 [回车默认 VLESS-$port]: " remark
    remark="${remark:-VLESS-$port}"

    # NAT 模式读取外部信息
    local nat_info=$(read_nat_info)
    local ext_ip=$(echo "$nat_info" | cut -d'|' -f1)
    local ext_port=$(echo "$nat_info" | cut -d'|' -f2)

    # 写入 nodes.txt（新增 ipver 字段）
    echo "vless|$port|$uuid|xtls-rprx-vision|$sni|$privkey|$pubkey|$shortid|$remark|$ipver|$ext_ip|$ext_port" >> "$NODES_DB"

    # 重建配置 + 防火墙 + 重启
    rebuild_config
    open_firewall "$port"
    restart_xray

    # 生成链接用的 IP 和端口
    local link_ip="${ext_ip:-$default_ip}"
    local link_port="${ext_port:-$port}"
    local link_host=$(fmt_host "$link_ip" "$link_port")

    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    msg "节点创建成功！"
    echo -e "  IP版本: ${B}IPv${ipver}${N}"
    echo -e "  端口:   ${B}$port${N}"
    echo -e "  UUID:   ${B}$uuid${N}"
    echo -e "  SNI:    ${B}$sni${N}"
    [ -n "$ext_ip" ] && echo -e "  外部:   ${B}$ext_ip:$ext_port → 内部 $port${N}"
    echo ""
    echo -e "  客户端链接:"
    echo -e "  ${G}vless://${uuid}@${link_host}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pubkey}&sid=${shortid}&spx=%2F&type=tcp#${remark}${N}"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ============================================
#  添加 Shadowsocks 节点
# ============================================

add_ss() {
    echo -e "\n${B}━━━ 添加 Shadowsocks 节点 ━━━${N}\n"

    # 选择 IP 版本
    local ip_info=$(choose_ip)
    local ipver=$(echo "$ip_info" | cut -d'|' -f1)
    local default_ip=$(echo "$ip_info" | cut -d'|' -f2)

    local port=$(read_port)

    local default_method="aes-256-gcm"
    read -p "加密方式 [回车默认 $default_method]: " method
    method="${method:-$default_method}"

    local password=$(openssl rand -base64 16 | tr -d '=/+')

    read -p "节点备注 [回车默认 SS-$port]: " remark
    remark="${remark:-SS-$port}"

    # NAT 模式读取外部信息
    local nat_info=$(read_nat_info)
    local ext_ip=$(echo "$nat_info" | cut -d'|' -f1)
    local ext_port=$(echo "$nat_info" | cut -d'|' -f2)

    # 写入 nodes.txt（新增 ipver 字段）
    echo "ss|$port|$method|$password|$remark|$ipver|$ext_ip|$ext_port" >> "$NODES_DB"

    # 重建配置 + 防火墙 + 重启
    rebuild_config
    open_firewall "$port"
    restart_xray

    # 生成链接用的 IP 和端口
    local link_ip="${ext_ip:-$default_ip}"
    local link_port="${ext_port:-$port}"
    local link_host=$(fmt_host "$link_ip" "$link_port")
    local ss_link=$(printf "%s:%s@%s" "$method" "$password" "$link_host" | b64_encode)

    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    msg "节点创建成功！"
    echo -e "  IP版本:   ${B}IPv${ipver}${N}"
    echo -e "  端口:     ${B}$port${N}"
    echo -e "  加密方式: ${B}$method${N}"
    echo -e "  密码:     ${B}$password${N}"
    [ -n "$ext_ip" ] && echo -e "  外部:     ${B}$ext_ip:$ext_port → 内部 $port${N}"
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
    while IFS='|' read -r type port f3 f4 f5 f6 f7 f8 f9 f10 f11 f12; do
        local ipver="4" ext_ip="" ext_port="" link_ip="" link_port=""

        if [ "$type" = "vless" ]; then
            # 新格式: f10=ipver, f11=ext_ip, f12=ext_port
            if [ "$f10" = "4" ] || [ "$f10" = "6" ]; then
                ipver="$f10"; ext_ip="$f11"; ext_port="$f12"
            else
                ext_ip="$f10"; ext_port="$f11"
            fi
            link_ip="${ext_ip:-$PUBLIC_IP}"
            link_port="${ext_port:-$port}"
            local link_host=$(fmt_host "$link_ip" "$link_port")
            echo -e "  ${G}$i${N}. ${B}[VLESS+Reality]${N} $f9 ${Y}(IPv${ipver})${N}"
            echo -e "     端口: $port | SNI: $f5"
            [ -n "$ext_ip" ] && echo -e "     NAT:  $ext_ip:$ext_port → 内部 $port"
            echo -e "     链接: vless://${f3}@${link_host}?encryption=none&flow=${f4}&security=reality&sni=${f5}&fp=chrome&pbk=${f7}&sid=${f8}&spx=%2F&type=tcp#${f9}"
        elif [ "$type" = "ss" ]; then
            # 新格式: f6=ipver, f7=ext_ip, f8=ext_port
            if [ "$f6" = "4" ] || [ "$f6" = "6" ]; then
                ipver="$f6"; ext_ip="$f7"; ext_port="$f8"
            else
                ext_ip="$f6"; ext_port="$f7"
            fi
            link_ip="${ext_ip:-$PUBLIC_IP}"
            link_port="${ext_port:-$port}"
            local link_host=$(fmt_host "$link_ip" "$link_port")
            local ss_link=$(printf "%s:%s@%s" "$f3" "$f4" "$link_host" | b64_encode)
            echo -e "  ${G}$i${N}. ${B}[Shadowsocks]${N} $f5 ${Y}(IPv${ipver})${N}"
            echo -e "     端口: $port | 加密: $f3"
            [ -n "$ext_ip" ] && echo -e "     NAT:  $ext_ip:$ext_port → 内部 $port"
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
    local remark=$(echo "$line" | cut -d'|' -f9)
    [ -z "$remark" ] && remark=$(echo "$line" | cut -d'|' -f5)

    echo ""
    warn "即将删除: 端口 $port ($remark)"
    read -p "确认删除? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { warn "已取消"; return; }

    sed -i "${num}d" "$NODES_DB"

    rebuild_config
    close_firewall "$port"
    restart_xray
    msg "节点已删除"
}

# ============================================
#  修改节点端口
# ============================================

modify_port() {
    if [ ! -f "$NODES_DB" ] || [ ! -s "$NODES_DB" ]; then
        warn "暂无节点"
        return
    fi

    list_nodes
    echo ""
    read -p "输入要修改的节点编号: " num

    local total=$(wc -l < "$NODES_DB")
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$total" ]; then
        err "无效编号"
        return
    fi

    local line=$(sed -n "${num}p" "$NODES_DB")
    local old_port=$(echo "$line" | cut -d'|' -f2)
    local remark=$(echo "$line" | cut -d'|' -f9)
    [ -z "$remark" ] && remark=$(echo "$line" | cut -d'|' -f5)

    echo ""
    msg "当前端口: $old_port ($remark)"
    local new_port=$(read_port)

    # 关闭旧端口防火墙
    close_firewall "$old_port"

    # 替换 nodes.txt 中的端口（第2个字段）
    sed -i "${num}s/^[^|]*|[^|]*/$(echo "$line" | cut -d'|' -f1)|${new_port}/" "$NODES_DB"

    # 重建配置 + 开放新端口防火墙 + 重启
    rebuild_config
    open_firewall "$new_port"
    restart_xray

    echo ""
    msg "端口已修改: $old_port → $new_port ($remark)"
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

    while IFS='|' read -r type port f3 f4 f5 f6 f7 f8 f9 f10 f11 f12; do
        local ext_ip="" ext_port="" link_ip="" link_port=""

        if [ "$type" = "vless" ]; then
            if [ "$f10" = "4" ] || [ "$f10" = "6" ]; then
                ext_ip="$f11"; ext_port="$f12"
            else
                ext_ip="$f10"; ext_port="$f11"
            fi
            link_ip="${ext_ip:-$PUBLIC_IP}"
            link_port="${ext_port:-$port}"
            local link_host=$(fmt_host "$link_ip" "$link_port")
            echo "vless://${f3}@${link_host}?encryption=none&flow=${f4}&security=reality&sni=${f5}&fp=chrome&pbk=${f7}&sid=${f8}&spx=%2F&type=tcp#${f9}"
        elif [ "$type" = "ss" ]; then
            if [ "$f6" = "4" ] || [ "$f6" = "6" ]; then
                ext_ip="$f7"; ext_port="$f8"
            else
                ext_ip="$f6"; ext_port="$f7"
            fi
            link_ip="${ext_ip:-$PUBLIC_IP}"
            link_port="${ext_port:-$port}"
            local link_host=$(fmt_host "$link_ip" "$link_port")
            local ss_link=$(printf "%s:%s@%s" "$f3" "$f4" "$link_host" | b64_encode)
            echo "ss://${ss_link}#${f5}"
        fi
    done < "$NODES_DB"

    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ============================================
#  卸载
# ============================================

uninstall() {
    echo -e "\n${B}━━━ 卸载 Xray 及所有节点 ━━━${N}\n"
    warn "此操作将:"
    warn "  1. 停止并禁用 xray 服务"
    warn "  2. 删除所有节点数据 (nodes.txt)"
    warn "  3. 删除 xray 配置文件"
    warn "  4. 关闭所有节点防火墙端口"
    warn "  5. 卸载 xray 程序"
    echo ""
    echo -e "  ${R}此操作不可恢复！${N}"
    echo ""
    read -p "确认卸载? 输入 YES 确认: " confirm
    [ "$confirm" = "YES" ] || { warn "已取消"; return; }

    # 关闭所有节点防火墙端口
    if [ -f "$NODES_DB" ] && [ -s "$NODES_DB" ]; then
        msg "关闭防火墙端口..."
        while IFS='|' read -r _type _port _rest; do
            [ -n "$_port" ] && close_firewall "$_port"
        done < "$NODES_DB"
    fi

    # 停止并禁用服务
    msg "停止 xray 服务..."
    svc_stop
    svc_disable

    # 删除文件
    msg "清理文件..."
    rm -f "$NODES_DB"
    rm -f "$XRAY_CONF"
    rm -f "${XRAY_CONF}.bak"
    rm -rf /usr/local/etc/xray/
    rm -rf /var/log/xray/

    # 卸载 xray
    msg "卸载 xray..."
    if command -v xray &>/dev/null; then
        bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove 2>/dev/null || \
            rm -f /usr/local/bin/xray
    fi

    # 清理服务文件
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray@.service
    rm -f /etc/init.d/xray
    [ "$SVC_TYPE" = "systemd" ] && systemctl daemon-reload 2>/dev/null || true

    # 清理快捷命令
    rm -f /usr/local/bin/xff
    rm -f /usr/local/bin/xray-manager.sh

    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    msg "Xray 已完全卸载，VPS 恢复干净状态"
    msg "可以重新运行脚本开始配置"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    read -p "按回车退出..." dummy
    exit 0
}

# ============================================
#  BBR 加速
# ============================================

BBR_CONF="/etc/sysctl.d/99-bbr-xray.conf"
BBR_MODULES_CONF="/etc/modules-load.d/99-xray-bbr.conf"
BBR_BACKUP_PREFIX="xray-bbr-backup"
BBR_SYSCTL_MARK="xray-bbr-disabled"

list_network_ifaces() {
    local iface_path iface operstate

    for iface_path in /sys/class/net/*; do
        [ -e "$iface_path" ] || continue
        iface="${iface_path##*/}"
        [ "$iface" = "lo" ] && continue

        operstate=""
        if [ -r "$iface_path/operstate" ]; then
            read -r operstate < "$iface_path/operstate"
        fi

        case "$operstate" in
            down|dormant|lowerlayerdown|notpresent) continue ;;
        esac

        printf "%s\n" "$iface"
    done
}

root_qdisc_of() {
    command -v tc >/dev/null 2>&1 || return 1
    tc qdisc show dev "$1" 2>/dev/null | awk 'NR==1 {print $2}'
}

list_qdisc_ifaces() {
    local iface qdisc

    for iface in $(list_network_ifaces); do
        qdisc=$(root_qdisc_of "$iface")
        [ -z "$qdisc" ] && continue
        [ "$qdisc" = "noqueue" ] && continue
        printf "%s\n" "$iface"
    done
}

default_route_iface() {
    local iface=""

    if command -v ip >/dev/null 2>&1; then
        iface=$(ip route show default 2>/dev/null | awk 'NR==1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    fi

    if [ -n "$iface" ]; then
        printf "%s\n" "$iface"
        return
    fi

    list_qdisc_ifaces | head -1
}

first_live_qdisc() {
    local iface qdisc

    iface=$(default_route_iface)
    if [ -n "$iface" ]; then
        qdisc=$(root_qdisc_of "$iface")
        [ -n "$qdisc" ] && printf "%s\n" "$qdisc"
    fi
}

live_qdisc_matches() {
    local expected="$1" iface qdisc found=0

    command -v tc >/dev/null 2>&1 || return 1
    for iface in $(list_qdisc_ifaces); do
        found=1
        qdisc=$(root_qdisc_of "$iface")
        [ "$qdisc" = "$expected" ] || return 1
    done

    [ "$found" -eq 1 ]
}

apply_live_qdisc() {
    local target="$1" iface found=0 failed=0

    if ! command -v tc >/dev/null 2>&1; then
        warn "未找到 tc 命令，无法立即切换当前网卡 qdisc；重启网卡或系统后会使用 sysctl 默认值"
        return 1
    fi

    for iface in $(list_qdisc_ifaces); do
        found=1
        if tc qdisc replace dev "$iface" root "$target" 2>/dev/null; then
            msg "网卡 $iface 当前 qdisc 已切换为 $target"
        else
            warn "网卡 $iface 切换 qdisc 到 $target 失败，保持当前设置"
            failed=1
        fi
    done

    if [ "$found" -eq 0 ]; then
        warn "未找到可切换 root qdisc 的非 lo 网卡"
        return 1
    fi

    return "$failed"
}

show_live_qdisc() {
    local iface qdisc printed=0

    if ! command -v tc >/dev/null 2>&1; then
        echo -e "  当前网卡队列: ${Y}无法检测（tc 未安装）${N}"
        return
    fi

    for iface in $(list_network_ifaces); do
        qdisc=$(root_qdisc_of "$iface")
        [ -z "$qdisc" ] && continue
        printed=1
        echo -e "  网卡 $iface 队列: ${B}$qdisc${N}"
    done

    [ "$printed" -eq 0 ] && echo -e "  当前网卡队列: ${Y}未检测到${N}"
}

write_bbr_conf() {
    local backup_qdisc="$1" backup_cc="$2" backup_live_qdisc="$3" backup_line=""
    local legacy_values="" legacy_qdisc="" legacy_cc="" legacy_live_qdisc=""

    if [ -f "$BBR_CONF" ]; then
        backup_line=$(head -1 "$BBR_CONF" 2>/dev/null)
    fi

    if [[ "$backup_line" =~ ^#${BBR_BACKUP_PREFIX}: ]]; then
        :
    elif [[ "$backup_line" == \#*:* ]]; then
        legacy_values="${backup_line#\#}"
        legacy_qdisc=$(echo "$legacy_values" | cut -d: -f1)
        legacy_cc=$(echo "$legacy_values" | cut -d: -f2)
        legacy_live_qdisc=$(echo "$legacy_values" | cut -d: -f3)

        case "$legacy_qdisc" in ""|*[!A-Za-z0-9_-]*) legacy_qdisc="$backup_qdisc" ;; esac
        case "$legacy_cc" in ""|*[!A-Za-z0-9_-]*) legacy_cc="$backup_cc" ;; esac
        case "$legacy_live_qdisc" in ""|*[!A-Za-z0-9_-]*) legacy_live_qdisc="${backup_live_qdisc:-$legacy_qdisc}" ;; esac
        backup_line="#${BBR_BACKUP_PREFIX}:${legacy_qdisc}:${legacy_cc}:${legacy_live_qdisc}"
    else
        backup_line="#${BBR_BACKUP_PREFIX}:${backup_qdisc}:${backup_cc}:${backup_live_qdisc}"
    fi

    printf "%s\n" "$backup_line" > "$BBR_CONF"
    printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" >> "$BBR_CONF"
}

enable_bbr() {
    echo -e "\n${B}━━━ 启用 BBR 加速 ━━━${N}\n"

    # 检查当前状态：sysctl 默认值不等于当前网卡真实 qdisc，必须同时验证
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local current_live_qdisc=$(first_live_qdisc)

    if [[ "$current_cc" == "bbr" ]] && [[ "$current_qdisc" == "fq" ]] && live_qdisc_matches fq; then
        msg "BBR 已启用，无需重复操作"
        echo -e "  当前拥塞控制: ${B}$current_cc${N}"
        echo -e "  默认队列算法: ${B}$current_qdisc${N}"
        show_live_qdisc
        return
    fi

    echo -e "  当前拥塞控制: ${Y}${current_cc:-未设置}${N}"
    echo -e "  默认队列算法: ${Y}${current_qdisc:-未设置}${N}"
    show_live_qdisc
    echo ""

    # 检查内核版本（BBR 需要 4.9+）
    local kv=$(uname -r | cut -d. -f1-2)
    local major=$(echo "$kv" | cut -d. -f1)
    local minor=$(echo "$kv" | cut -d. -f2)
    if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 9 ]; }; then
        err "内核版本 $(uname -r) 过低，BBR 需要 4.9+"
        return
    fi
    msg "内核版本: $(uname -r) (满足 BBR 要求)"

    # 加载 BBR 模块
    if ! modprobe tcp_bbr 2>/dev/null; then
        err "无法加载 tcp_bbr 模块，当前内核可能未编译 BBR 支持"
        return
    fi
    msg "tcp_bbr 模块已加载"

    # 确保 bbr 开机自动加载；使用脚本专属文件，避免覆盖用户已有 modules-load 配置
    printf "tcp_bbr\n" > "$BBR_MODULES_CONF"

    # 持久化写入
    if [ -d /etc/sysctl.d ]; then
        # 保存旧值到注释行，供 disable_bbr 回滚
        write_bbr_conf "$current_qdisc" "$current_cc" "$current_live_qdisc"

        # 注释掉 /etc/sysctl.conf 中已有的冲突行，避免两个文件打架
        if [ -f /etc/sysctl.conf ]; then
            sed -i -E "s/^[[:space:]]*(net\.core\.default_qdisc[[:space:]]*=.*)$/# ${BBR_SYSCTL_MARK} \1/" /etc/sysctl.conf
            sed -i -E "s/^[[:space:]]*(net\.ipv4\.tcp_congestion_control[[:space:]]*=.*)$/# ${BBR_SYSCTL_MARK} \1/" /etc/sysctl.conf
        fi

        sysctl --system &>/dev/null
    else
        # 没有 sysctl.d 的老系统，直接写 sysctl.conf；只标记和管理本脚本写入的配置
        if [ -f /etc/sysctl.conf ]; then
            sed -i -E "s/^[[:space:]]*(net\.core\.default_qdisc[[:space:]]*=.*)$/# ${BBR_SYSCTL_MARK} \1/" /etc/sysctl.conf
            sed -i -E "s/^[[:space:]]*(net\.ipv4\.tcp_congestion_control[[:space:]]*=.*)$/# ${BBR_SYSCTL_MARK} \1/" /etc/sysctl.conf
        fi
        printf "# ${BBR_SYSCTL_MARK} begin\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n# ${BBR_SYSCTL_MARK} end\n" >> /etc/sysctl.conf
        sysctl -p &>/dev/null
    fi

    # sysctl 只影响默认值，不会自动替换当前网卡已挂载的 root qdisc
    apply_live_qdisc fq || true

    # 验证
    local new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if [[ "$new_cc" == "bbr" ]] && [[ "$new_qdisc" == "fq" ]] && live_qdisc_matches fq; then
        echo ""
        echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        msg "BBR 加速已启用！"
        echo -e "  拥塞控制: ${B}$new_cc${N}"
        echo -e "  默认队列算法: ${B}$new_qdisc${N}"
        show_live_qdisc
        echo -e "  持久化:   ${B}${BBR_CONF}${N}"
        echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    else
        err "BBR 启用不完整，请检查内核、tc 命令和当前网卡 qdisc"
    fi
}

disable_bbr() {
    echo -e "\n${B}━━━ 关闭 BBR 加速 ━━━${N}\n"

    # 检查当前状态
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local restore_live_qdisc=""

    if [[ "$current_cc" != "bbr" ]] && [[ "$current_qdisc" != "fq" ]] && ! live_qdisc_matches fq && [ ! -f "$BBR_CONF" ]; then
        msg "BBR 未启用，无需操作"
        return
    fi

    if [ -f "$BBR_CONF" ]; then
        # 从注释行读取旧值回滚
        local old_values=$(head -1 "$BBR_CONF" | sed 's/^#//')
        local old_qdisc=""
        local old_cc=""
        local old_live_qdisc=""

        if [[ "$old_values" == ${BBR_BACKUP_PREFIX}:* ]]; then
            old_qdisc=$(echo "$old_values" | cut -d: -f2)
            old_cc=$(echo "$old_values" | cut -d: -f3)
            old_live_qdisc=$(echo "$old_values" | cut -d: -f4)
        else
            old_qdisc=$(echo "$old_values" | cut -d: -f1)
            old_cc=$(echo "$old_values" | cut -d: -f2)
            old_live_qdisc=$(echo "$old_values" | cut -d: -f3)
        fi

        case "$old_qdisc" in ""|*[!A-Za-z0-9_-]*) old_qdisc="pfifo_fast" ;; esac
        case "$old_cc" in ""|*[!A-Za-z0-9_-]*) old_cc="cubic" ;; esac
        case "$old_live_qdisc" in ""|*[!A-Za-z0-9_-]*) old_live_qdisc="$old_qdisc" ;; esac
        restore_live_qdisc="$old_live_qdisc"

        msg "恢复原始设置: 拥塞控制=$old_cc, 默认队列算法=$old_qdisc, 当前网卡队列=$old_live_qdisc"

        # 删除 BBR 配置文件
        rm -f "$BBR_CONF"

        # 只恢复本脚本启用 BBR 时加标记注释的行，避免误启用用户原本手动注释的配置
        if [ -f /etc/sysctl.conf ]; then
            sed -i -E "/^#[[:space:]]*${BBR_SYSCTL_MARK}[[:space:]]+begin$/,/^#[[:space:]]*${BBR_SYSCTL_MARK}[[:space:]]+end$/d" /etc/sysctl.conf
            sed -i -E "s/^#[[:space:]]*${BBR_SYSCTL_MARK}[[:space:]]+(net\.core\.default_qdisc[[:space:]]*=.*)$/\1/" /etc/sysctl.conf
            sed -i -E "s/^#[[:space:]]*${BBR_SYSCTL_MARK}[[:space:]]+(net\.ipv4\.tcp_congestion_control[[:space:]]*=.*)$/\1/" /etc/sysctl.conf
        fi

        sysctl -w net.core.default_qdisc="$old_qdisc" &>/dev/null
        sysctl -w net.ipv4.tcp_congestion_control="$old_cc" &>/dev/null
        sysctl --system &>/dev/null
    else
        # 没有脚本备份时，不强制回退用户当前 BBR/sysctl/qdisc 设置，只清理本脚本标记过的配置
        warn "未找到 BBR 配置备份，仅清理本脚本标记的配置；未修改当前 sysctl/qdisc 运行状态"

        if [ -f /etc/sysctl.conf ]; then
            sed -i -E "/^#[[:space:]]*${BBR_SYSCTL_MARK}[[:space:]]+begin$/,/^#[[:space:]]*${BBR_SYSCTL_MARK}[[:space:]]+end$/d" /etc/sysctl.conf
            sed -i -E "s/^#[[:space:]]*${BBR_SYSCTL_MARK}[[:space:]]+(net\.core\.default_qdisc[[:space:]]*=.*)$/\1/" /etc/sysctl.conf
            sed -i -E "s/^#[[:space:]]*${BBR_SYSCTL_MARK}[[:space:]]+(net\.ipv4\.tcp_congestion_control[[:space:]]*=.*)$/\1/" /etc/sysctl.conf
        fi

        sysctl --system &>/dev/null || sysctl -p &>/dev/null
    fi

    # sysctl 只恢复默认值，不会自动替换当前网卡已挂载的 root qdisc
    [ -n "$restore_live_qdisc" ] && apply_live_qdisc "$restore_live_qdisc" || true

    # 移除本脚本创建的模块开机自加载配置，不触碰用户自己的 modules-load 文件
    rm -f "$BBR_MODULES_CONF"

    # 验证
    local new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if [[ "$new_cc" != "bbr" ]]; then
        echo ""
        echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        msg "BBR 已关闭！"
        echo -e "  拥塞控制: ${B}$new_cc${N}"
        echo -e "  默认队列算法: ${B}$new_qdisc${N}"
        show_live_qdisc
        echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    else
        err "BBR 关闭失败，请手动检查 sysctl 配置"
    fi
}

bbr_menu() {
    echo -e "\n${B}━━━ BBR 加速管理 ━━━${N}\n"

    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    echo -e "  当前状态: 拥塞控制=${B}$current_cc${N}, 默认队列算法=${B}$current_qdisc${N}"
    show_live_qdisc
    echo ""
    echo -e "  ${B}1.${N} 启用 BBR"
    echo -e "  ${B}2.${N} 关闭 BBR"
    echo -e "  ${B}0.${N} 返回主菜单"
    echo ""
    read -p "请选择 [0-2]: " bbr_choice

    case $bbr_choice in
        1) enable_bbr ;;
        2) disable_bbr ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
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
    echo "║   快捷命令: xff                       ║"
    echo "╚═══════════════════════════════════════╝"
    echo -e "${N}"
    echo -e "  ${B}1.${N} 添加 VLESS+Reality 节点"
    echo -e "  ${B}2.${N} 添加 Shadowsocks 节点"
    echo -e "  ${B}3.${N} 查看所有节点"
    echo -e "  ${B}4.${N} 删除节点"
    echo -e "  ${B}5.${N} 修改节点端口"
    echo -e "  ${B}6.${N} 导出所有链接"
    echo -e "  ${B}7.${N} 卸载 (清空所有数据)"
    echo -e "  ${B}8.${N} BBR 加速"
    echo -e "  ${B}0.${N} 退出"
    echo ""
    read -p "请选择 [0-8]: " choice

    case $choice in
        1) add_vless ;;
        2) add_ss ;;
        3) list_nodes ;;
        4) delete_node ;;
        5) modify_port ;;
        6) export_links ;;
        7) uninstall ;;
        8) bbr_menu ;;
        0) echo -e "\n再见！"; exit 0 ;;
        *) warn "无效选择" ;;
    esac

    echo ""
    read -p "按回车键继续..."
}

# ============================================
#  安装快捷命令 xff
# ============================================

install_shortcut() {
    local script_path="/usr/local/bin/xray-manager.sh"
    local shortcut="/usr/local/bin/xff"

    if [ ! -f "$script_path" ] || ! grep -q "Xray 节点管理" "$script_path" 2>/dev/null; then
        curl -fsSL --connect-timeout 10 --max-time 60 \
            "https://raw.githubusercontent.com/masatoshiyokoyama635-sudo/vps-scripts/master/xray-manager.sh" \
            -o "$script_path" 2>/dev/null || \
        wget -qO "$script_path" \
            "https://raw.githubusercontent.com/masatoshiyokoyama635-sudo/vps-scripts/master/xray-manager.sh" 2>/dev/null
        chmod +x "$script_path"
    fi

    if [ ! -L "$shortcut" ] && [ ! -f "$shortcut" ]; then
        ln -sf "$script_path" "$shortcut"
        msg "快捷命令 xff 已安装，以后输入 xff 即可进入管理"
    fi
}

# ============================================
#  入口
# ============================================

main() {
    detect_os
    check_deps
    install_shortcut

    # 兼容旧版 nodes.txt：为没有 ipver 字段的行插入 "4" 到 remark 后面
    # 正确格式: vless|...|remark|ipver|ext_ip|ext_port
    # 旧格式:   vless|...|remark|ext_ip|ext_port (缺 ipver)
    if [ -f "$NODES_DB" ] && [ -s "$NODES_DB" ]; then
        local migrated=false
        while IFS= read -r line; do
            local field_count=$(echo "$line" | awk -F'|' '{print NF}')
            if [[ "$line" == vless* ]] && [ "$field_count" -eq 11 ]; then
                # 在 field 9 (remark) 后插入 "4"：fields 1-9 | 4 | fields 10-11
                echo "$line" | awk -F'|' -v OFS='|' '{print $1,$2,$3,$4,$5,$6,$7,$8,$9,"4",$10,$11}' >> "${NODES_DB}.new"
                migrated=true
            elif [[ "$line" == ss* ]] && [ "$field_count" -eq 7 ]; then
                # 在 field 5 (remark) 后插入 "4"：fields 1-5 | 4 | fields 6-7
                echo "$line" | awk -F'|' -v OFS='|' '{print $1,$2,$3,$4,$5,"4",$6,$7}' >> "${NODES_DB}.new"
                migrated=true
            else
                echo "$line" >> "${NODES_DB}.new"
            fi
        done < "$NODES_DB"
        if [ "$migrated" = true ]; then
            mv "${NODES_DB}.new" "$NODES_DB"
            msg "已迁移旧版节点数据（补充 IPv4 版本字段）"
        else
            rm -f "${NODES_DB}.new"
        fi
        # 清理旧版遗留的尾部空管道符
        sed -i '/^vless|/s/|$//' "$NODES_DB" 2>/dev/null
    fi

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
