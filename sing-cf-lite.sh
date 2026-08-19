#!/usr/bin/env bash
set -euo pipefail

# ── 常量与路径 ─────────────────────────────────────────
SINGBOX_DIR="/etc/sing-box"
SINGBOX_CONFIG="$SINGBOX_DIR/config.json"
SINGBOX_BINARY="/usr/local/bin/sing-box"
STATE_DIR="/etc/singbox-cf-lite"
STATE_PATH="$STATE_DIR/state.json"
CF_ACCOUNT_PATH="$STATE_DIR/cf_account.json"
LAST_LINKS_PATH="$(pwd)/singbox_cf_links.txt"

CF_API="https://api.cloudflare.com/client/v4"
MANAGED_PREFIX="singbox-nat "

# ── 基础工具 ───────────────────────────────────────────
die()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()      { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
info()    { printf '\033[36m·\033[0m %s\n' "$*" >&2; }
need_cmd(){ command -v "$1" &>/dev/null || die "缺少依赖: $1"; }

urlencode() {
    local s="$1" c i
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}
gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]'; }

# ── init 与依赖 ───────────────────────────────────────
INIT_SYSTEM=""
detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then INIT_SYSTEM="openrc"
    else die "不支持的 init 系统"; fi
}

install_deps() {
    local missing=()
    for cmd in curl jq wget tar openssl uuidgen; do
        command -v $cmd &>/dev/null || missing+=($cmd)
    done
    [[ ${#missing[@]} -eq 0 ]] && return
    info "安装依赖: ${missing[*]}"
    if command -v apk &>/dev/null; then apk add --no-cache curl jq wget tar openssl util-linux
    elif command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y -qq curl jq wget tar openssl uuid-runtime
    else die "请手动安装依赖: ${missing[*]}"; fi
}

# ── 核心下载与服务配置 ─────────────────────────────────
install_singbox() {
    info "获取 Sing-box 最新版本..."
    local ver ver_num arch dl_arch tmp_dir
    ver=$(curl -sf "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    [[ -z "$ver" || "$ver" == "null" ]] && die "获取最新版本号失败，请检查网络"
    ver_num=${ver#v}
    
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) dl_arch="amd64" ;;
        aarch64|arm64) dl_arch="arm64" ;;
        armv7*) dl_arch="armv7" ;;
        *) die "不支持的 CPU 架构: $arch" ;;
    esac

    local dl_url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver_num}-linux-${dl_arch}.tar.gz"
    info "下载: $dl_url"
    
    tmp_dir="/tmp/singbox-dl-$$"
    mkdir -p "$tmp_dir"
    wget -qO "$tmp_dir/singbox.tar.gz" "$dl_url" || die "下载失败"
    
    tar -xzf "$tmp_dir/singbox.tar.gz" -C "$tmp_dir" || die "解压失败"
    mkdir -p /usr/local/bin
    
    # 精准移动，防误删
    mv "$tmp_dir/sing-box-${ver_num}-linux-${dl_arch}/sing-box" "$SINGBOX_BINARY"
    chmod +x "$SINGBOX_BINARY"
    rm -rf "$tmp_dir"
    
    ok "Sing-box $ver 安装成功"
}

setup_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=2
LimitNOFILE=infinity
Environment="GOGC=20"
Environment="GOMEMLIMIT=25MiB"
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box &>/dev/null
    else
        cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
command_env="GOGC=20 GOMEMLIMIT=25MiB"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default &>/dev/null
    fi
}

svc_start() { [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl restart sing-box || rc-service sing-box restart; }
svc_stop()  { [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl stop sing-box || rc-service sing-box stop; }

# ── CF API 核心交互 ───────────────────────────────────
cf_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

load_cf_account() {
    [[ -f "$CF_ACCOUNT_PATH" ]] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_PATH")
    CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_PATH")
    [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]
}

save_cf_account() {
    mkdir -p "$STATE_DIR"
    jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" '{email:$e,api_key:$k}' > "$CF_ACCOUNT_PATH"
    chmod 600 "$CF_ACCOUNT_PATH"
}

prompt_cf() {
    if load_cf_account; then return 0; fi
    while true; do
        read -rp "Cloudflare 邮箱: " CF_EMAIL
        read -rsp "Cloudflare Global API Key: " CF_KEY; echo
        local check; check=$(cf_call GET "/zones?per_page=1" | jq -e '.success == true' 2>/dev/null)
        if [[ "$check" == "true" ]]; then
            save_cf_account; return 0
        fi
        echo "失败：邮箱或 API Key 错误，请重新输入"
    done
}

# ── 路由与配置生成 ─────────────────────────────────────
gen_singbox_config() {
    local port="$1" uuid="$2" path="$3"
    # 兼容最新版 Sing-box (v1.9+) 的标准 JSON 格式，剔除遗留废弃字段
    jq -n --argjson p "$port" --arg u "$uuid" --arg pa "$path" '{
      log: { disabled: true },
      inbounds: [{
        type: "vless",
        tag: "in-vless",
        listen: "::",
        listen_port: $p,
        users: [{ uuid: $u, flow: "" }],
        transport: { type: "ws", path: $pa }
      }],
      outbounds: [{ type: "direct", tag: "direct" }]
    }'
}

build_vless_link() {
    local uuid="$1" domain="$2" path="$3" ip_or_domain="${4:-$domain}"
    local enc_path; enc_path=$(urlencode "$path")
    # 生成标准的 VLESS 链接，通过指定 host 和 sni，让前面的 IP 可以随意更换 (优选)
    echo "vless://${uuid}@${ip_or_domain}:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${enc_path}#SB-CF-${domain}"
}

# ── 核心逻辑：安装 ─────────────────────────────────────
do_install() {
    [[ -f "$STATE_PATH" ]] && die "已存在配置，请先使用菜单 2 卸载"
    install_singbox
    prompt_cf

    local domain zone_id
    while true; do
        read -rp "主域名 (例如 example.com): " main_domain
        zone_id=$(cf_call GET "/zones?name=$main_domain" | jq -r '.result[0].id // ""')
        [[ -n "$zone_id" ]] && break
        echo "未能找到该域名的 Zone，请重试"
    done

    read -rp "节点完整域名 (例如 sub.example.com): " domain
    read -rp "内部监听端口 (默认 8080): " in_port; in_port=${in_port:-8080}
    read -rp "外部映射端口 (NAT公网端口，直连则填 443): " ext_port; ext_port=${ext_port:-443}
    
    local uuid; uuid=$(gen_uuid)
    local ws_path="/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)"

    # 1. 写配置并重启
    mkdir -p "$SINGBOX_DIR"
    gen_singbox_config "$in_port" "$uuid" "$ws_path" > "$SINGBOX_CONFIG"
    setup_service
    svc_start
    ok "Sing-box 服务已启动"

    # 2. CF DNS
    local public_ip; public_ip=$(curl -s ipv4.icanhazip.com)
    local record_id; record_id=$(cf_call GET "/zones/$zone_id/dns_records?name=$domain" | jq -r '.result[0].id // ""')
    local dns_payload="{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$public_ip\",\"proxied\":true}"
    if [[ -z "$record_id" ]]; then
        record_id=$(cf_call POST "/zones/$zone_id/dns_records" "$dns_payload" | jq -r '.result.id')
    else
        cf_call PUT "/zones/$zone_id/dns_records/$record_id" "$dns_payload" >/dev/null
    fi
    ok "CF DNS 记录已设置 (小云朵开启)"

    # 3. CF SSL & Origin Rules (无视端口映射)
    cf_call PATCH "/zones/$zone_id/settings/ssl" '{"value":"flexible"}' >/dev/null
    local ruleset_id; ruleset_id=$(cf_call GET "/zones/$zone_id/rulesets" | jq -r '.result[] | select(.phase=="http_request_origin").id // ""')
    local rule_data="{\"description\":\"${MANAGED_PREFIX}Port\",\"expression\":\"(http.host eq \\\"$domain\\\")\",\"action\":\"route\",\"action_parameters\":{\"origin\":{\"port\":$ext_port}}}"
    
    if [[ -z "$ruleset_id" ]]; then
        cf_call POST "/zones/$zone_id/rulesets" "{\"name\":\"default\",\"phase\":\"http_request_origin\",\"rules\":[$rule_data]}" >/dev/null
    else
        cf_call POST "/zones/$zone_id/rulesets/$ruleset_id/rules" "$rule_data" >/dev/null
    fi
    ok "CF Origin Rules (NAT端口穿透) 已配置"

    # 4. CF 放行 WAF (禁用 Browser Check 和 Bot Fight Mode)
    cf_call PATCH "/zones/$zone_id/settings/security_level" '{"value":"essentially_off"}' >/dev/null
    cf_call PATCH "/zones/$zone_id/settings/browser_check" '{"value":"off"}' >/dev/null
    cf_call PUT "/zones/$zone_id/bot_management" '{"enable_js":false,"sbfm_likely_automated":"allow","sbfm_definitely_automated":"allow","sbfm_verified_bots":"allow","sbfm_static_resource_protection":false}' >/dev/null
    ok "WAF 拦截已自动放行"

    # 5. 保存状态与生成链接
    local link_default; link_default=$(build_vless_link "$uuid" "$domain" "$ws_path" "$domain")
    local link_opt; link_opt=$(build_vless_link "$uuid" "$domain" "$ws_path" "104.16.1.1") # 示例优选IP
    
    jq -n --arg d "$domain" --arg z "$zone_id" --arg u "$uuid" --arg p "$ws_path" \
        --argjson ip "$in_port" --argjson ep "$ext_port" --arg rid "$record_id" \
        '{domain:$d, zone_id:$z, uuid:$u, path:$p, in_port:$ip, ext_port:$ep, dns_id:$rid}' > "$STATE_PATH"

    echo -e "\n${GREEN}=== 部署完成 ===${PLAIN}"
    echo "默认节点（未优选，适合直连测试）:"
    echo -e "\033[33m$link_default\033[0m\n"
    echo "优选IP节点模板（地址已替换为104.16.x.x，可自行更换其他优选IP或CNAME）:"
    echo -e "\033[36m$link_opt\033[0m\n"
}

# ── 卸载 ───────────────────────────────────────────────
do_uninstall() {
    [[ -f "$STATE_PATH" ]] || die "未检测到配置"
    local domain zone_id dns_id
    domain=$(jq -r '.domain' "$STATE_PATH")
    zone_id=$(jq -r '.zone_id' "$STATE_PATH")
    dns_id=$(jq -r '.dns_id' "$STATE_PATH")

    svc_stop
    rm -rf "$SINGBOX_DIR"
    
    if load_cf_account; then
        info "正在清理 CF 配置..."
        cf_call DELETE "/zones/$zone_id/dns_records/$dns_id" >/dev/null 2>&1 || true
        # 清理 Origin rules
        local rset_id; rset_id=$(cf_call GET "/zones/$zone_id/rulesets" | jq -r '.result[] | select(.phase=="http_request_origin").id // ""')
        if [[ -n "$rset_id" ]]; then
            local r_id; r_id=$(cf_call GET "/zones/$zone_id/rulesets/$rset_id" | jq -r ".result.rules[]? | select(.description | startswith(\"$MANAGED_PREFIX\")).id // \"\"")
            [[ -n "$r_id" ]] && cf_call DELETE "/zones/$zone_id/rulesets/$rset_id/rules/$r_id" >/dev/null
        fi
        ok "CF 域名与规则清理完毕"
    fi
    rm -rf "$STATE_DIR"
    ok "完全卸载成功"
}

# ── 菜单流转 ───────────────────────────────────────────
main() {
    [[ "$(id -u)" == "0" ]] || die "请使用 root 运行"
    detect_init; install_deps
    
    GREEN="\033[32m"; YELLOW="\033[33m"; PLAIN="\033[0m"
    local domain=""; [[ -f "$STATE_PATH" ]] && domain=$(jq -r '.domain' "$STATE_PATH")

    echo
    echo -e "${GREEN}  Sing-box CF Lite 终极面板${PLAIN}"
    echo
    echo "  1. 🚀 一键全新安装"
    echo "  2. 🗑️ 完全卸载并恢复 CF 设置"
    echo "  3. 🔗 查看节点链接与优选指南"
    echo "  4. 🔄 重启 Sing-box 服务"
    [[ -n "$domain" ]] && echo -e "     (${YELLOW}当前节点: $domain${PLAIN})"
    echo

    read -rp "请选择 [1-4]: " choice
    case "$choice" in
        1) do_install ;;
        2) do_uninstall ;;
        3) 
            [[ -f "$STATE_PATH" ]] || die "未安装"
            u=$(jq -r '.uuid' "$STATE_PATH")
            d=$(jq -r '.domain' "$STATE_PATH")
            p=$(jq -r '.path' "$STATE_PATH")
            echo -e "\n默认连接:\n\033[33m$(build_vless_link "$u" "$d" "$p" "$d")\033[0m\n"
            echo -e "优选IP示范 (随意更改 @ 到 :443 之间的IP即可，不影响伪装):\n\033[36m$(build_vless_link "$u" "$d" "$p" "104.16.1.1")\033[0m\n"
            ;;
        4) svc_start && ok "重启成功" ;;
        *) die "无效选择" ;;
    esac
}

main "$@"
