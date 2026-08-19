#!/usr/bin/env bash
set -euo pipefail
# ==========================================
# 项目: sing-box CF Lite (NAT 小鸡优化版)
# 参考: xray-cf-lite 架构重写
# 适配: Alpine (OpenRC) / Debian (Systemd)
# 特性: 状态管理 / 凭据复用 / 卸载恢复 / 配置热改 / gcompat自动修复
# ==========================================

# ── 常量 ──────────────────────────────────────────────
SB_BINARY="/usr/local/bin/sing-box"
SB_CONFIG_DIR="/etc/sing-box"
SB_CONFIG_PATH="$SB_CONFIG_DIR/config.json"
SB_LOG="/var/log/sing-box.log"

STATE_DIR="/etc/sb-cf-lite"
STATE_PATH="$STATE_DIR/state.json"
CF_ACCOUNT_PATH="$STATE_DIR/cf_account.json"
LAST_LINKS_PATH="$(pwd)/sb_cf_lite_last_links.txt"

CF_API="https://api.cloudflare.com/client/v4"
MANAGED_PREFIX="sb-cf-lite "

# 内存调优（64M 小鸡）
MEM_LIMIT="48MiB"
GOGC_VAL="20"

# 颜色
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; PLAIN='\033[0m'

# ── 工具函数 ──────────────────────────────────────────
die()     { printf "${RED}✗ %s${PLAIN}\n" "$*" >&2; exit 1; }
ok()      { printf "${GREEN}✓${PLAIN} %s\n" "$*" >&2; }
info()    { printf "${CYAN}·${PLAIN} %s\n" "$*" >&2; }
warn()    { printf "${YELLOW}⚠ %s${PLAIN}\n" "$*" >&2; }
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

gen_path() { echo "/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)"; }

# ── init 系统检测 ─────────────────────────────────────
INIT_SYSTEM=""
detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

# ── 依赖安装 ──────────────────────────────────────────
install_deps() {
    local missing=()
    command -v curl  &>/dev/null || missing+=(curl)
    command -v jq    &>/dev/null || missing+=(jq)
    command -v wget  &>/dev/null || missing+=(wget)
    command -v openssl &>/dev/null || missing+=(openssl)
    command -v tar   &>/dev/null || missing+=(tar)
    [[ ${#missing[@]} -eq 0 ]] && return
    info "安装依赖: ${missing[*]}"
    if command -v apk &>/dev/null; then
        # gcompat + libc6-compat: Alpine musl 运行 glibc 编译的 sing-box 必需
        apk add --no-cache "${missing[@]}" gcompat libc6-compat
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}"
    else
        die "无法安装依赖，请手动安装: ${missing[*]}"
    fi
}

# ── sing-box 服务管理 ─────────────────────────────────
SB_OPENRC_SCRIPT="/etc/init.d/sing-box"

write_openrc_script() {
    cat > "$SB_OPENRC_SCRIPT" << 'INITEOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy server"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
respawn_delay=2
respawn_max=0
respawn_period=86400
supervise_daemon_args="--respawn-delay ${respawn_delay} --respawn-max ${respawn_max} --respawn-period ${respawn_period}"
supervisor=supervise-daemon
depend() { need net; after firewall; }
start_pre() {
    export GOGC="20"
    export GOMEMLIMIT="48MiB"
    checkpath -f -m 0644 /var/log/sing-box.log
}
INITEOF
    chmod +x "$SB_OPENRC_SCRIPT"
}

svc_enable() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl enable sing-box &>/dev/null
    else
        rc-update add sing-box default &>/dev/null
    fi
    true
}

svc_start() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart sing-box
    else
        [[ -f "$SB_OPENRC_SCRIPT" ]] || write_openrc_script
        rc-service sing-box restart
    fi
}

svc_stop() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop sing-box &>/dev/null; systemctl disable sing-box &>/dev/null
    else
        rc-service sing-box stop &>/dev/null; rc-update del sing-box default &>/dev/null
    fi
    true
}

svc_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active sing-box &>/dev/null
    else
        rc-service sing-box status &>/dev/null 2>&1
    fi
}

ensure_systemd_restart() {
    local drop="/etc/systemd/system/sing-box.service.d"
    if [[ "$INIT_SYSTEM" == "systemd" && ! -f "$drop/restart.conf" ]]; then
        mkdir -p "$drop"
        cat > "$drop/restart.conf" << 'SDEOF'
[Service]
Restart=on-failure
RestartSec=3
SDEOF
        systemctl daemon-reload
    fi
}

restart_sb() {
    [[ "$INIT_SYSTEM" == "systemd" ]] && ensure_systemd_restart
    svc_enable
    svc_start || die "sing-box 重启失败，查看日志: tail -20 $SB_LOG"
    sleep 2
    svc_is_active || die "sing-box 未正常启动，查看日志: tail -20 $SB_LOG"
    # 端口监听检查
    local port
    port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG_PATH" 2>/dev/null || echo "")
    if [[ -n "$port" ]]; then
        if command -v ss &>/dev/null; then
            ss -tlnp 2>/dev/null | grep -q ":$port " || die "端口 $port 未监听，服务可能异常"
        fi
    fi
    ok "sing-box 服务已启动 (PID $(pgrep -f 'sing-box run' | head -1))"
}

# ── 网络检测 ──────────────────────────────────────────
get_public_ip() {
    local ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -sf --max-time 8 "$url" 2>/dev/null) && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    done
    die "获取公网 IPv4 失败"
}

detect_nat() {
    local public_ip
    public_ip=$(get_public_ip)
    if ip addr show 2>/dev/null | grep -qE "inet ${public_ip}/"; then
        echo "direct"
    else
        echo "nat"
    fi
}

net_mode_label() {
    [[ "$1" == "direct" ]] && echo "直连（公网端口直达本机）" || echo "NAT（需要端口映射）"
}

prompt_net_mode() {
    local detected="$1" ans
    echo >&2
    info "网络环境探测结果: $(net_mode_label "$detected")" >&2
    if [[ "$detected" == "nat" ]]; then
        echo "  如果这台机器有独立公网 IP、外部能直接连到你要开的端口，选直连。" >&2
    else
        echo "  如果这台机器在 NAT/软路由后面，对外端口和本机监听端口不一致，选 NAT。" >&2
    fi
    read -rp "使用哪种模式? (1=直连, 2=NAT, 回车=用探测结果): " ans
    case "$ans" in
        1) echo "direct" ;;
        2) echo "nat" ;;
        "") echo "$detected" ;;
        *) die "无效选项: $ans" ;;
    esac
}

# ── CF API 封装 ───────────────────────────────────────
CF_EMAIL="" CF_KEY=""

cf_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -f -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

cf_call_raw() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

# ── CF 凭据管理 ───────────────────────────────────────
load_cf_account() {
    [[ -f "$CF_ACCOUNT_PATH" ]] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_PATH")
    CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_PATH")
    [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]
}

save_cf_account() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" '{email:$e,api_key:$k}' > "$CF_ACCOUNT_PATH"
    chmod 600 "$CF_ACCOUNT_PATH"
}

cf_verify_credentials() {
    local r
    r=$(curl -s -X GET "${CF_API}/zones?per_page=1" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    echo "$r" | jq -e '.success == true' &>/dev/null
}

prompt_cf() {
    if load_cf_account; then
        local masked="${CF_KEY:0:6}...${CF_KEY: -4}"
        read -rp "复用已保存 CF 凭据 ($CF_EMAIL, Key=$masked)? (Y/n): " ans
        if [[ "${ans,,}" =~ ^(|y|yes)$ ]]; then
            if cf_verify_credentials; then
                return 0
            fi
            warn "已保存的 CF 凭据校验失败，请重新输入"
        fi
    fi
    while true; do
        read -rp "Cloudflare 邮箱: " CF_EMAIL || die "输入已中断"
        read -rsp "Cloudflare Global API Key: " CF_KEY || die "输入已中断"; echo
        if [[ -z "$CF_EMAIL" || -z "$CF_KEY" ]]; then
            warn "邮箱和 API Key 不能为空"
            continue
        fi
        echo -n "校验凭据... "
        if cf_verify_credentials; then
            echo "通过"
            save_cf_account
            return 0
        fi
        warn "失败：邮箱或 API Key 错误，请重新输入（注意是 Global API Key，不是 API Token）"
    done
}

# ── CF Zone / DNS / SSL ───────────────────────────────
cf_find_zone() {
    local domain="$1" zones best_name="" best_id=""
    zones=$(cf_call GET "/zones?per_page=100" | jq -r '.result[] | "\(.name) \(.id)"')
    while IFS=' ' read -r zone_name zone_id; do
        if [[ "$domain" == "$zone_name" || "$domain" == *".$zone_name" ]]; then
            [[ ${#zone_name} -gt ${#best_name} ]] && best_name="$zone_name" && best_id="$zone_id"
        fi
    done <<< "$zones"
    [[ -n "$best_id" ]] || return 1
    echo "$best_id"
}

cf_get_dns() {
    cf_call GET "/zones/$1/dns_records?type=A&name=$2" | jq '.result[0] // empty'
}

cf_upsert_dns() {
    local zone_id="$1" domain="$2" ip="$3"
    local payload existing
    payload=$(jq -n --arg n "$domain" --arg c "$ip" '{type:"A",name:$n,content:$c,proxied:true,ttl:1}')
    existing=$(cf_get_dns "$zone_id" "$domain")
    if [[ -n "$existing" ]]; then
        local rid; rid=$(echo "$existing" | jq -r '.id')
        cf_call PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" | jq -r '.result.id'
    else
        cf_call POST "/zones/${zone_id}/dns_records" "$payload" | jq -r '.result.id'
    fi
}

cf_get_ssl() { cf_call GET "/zones/$1/settings/ssl" | jq -r '.result.value'; }
cf_set_ssl() { cf_call PATCH "/zones/$1/settings/ssl" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

# ── CF 安全规则（备份/关闭/恢复）──────────────────────
cf_get_security_level() { cf_call GET "/zones/$1/settings/security_level" | jq -r '.result.value'; }
cf_set_security_level() { cf_call PATCH "/zones/$1/settings/security_level" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

cf_get_browser_check() { cf_call GET "/zones/$1/settings/browser_check" | jq -r '.result.value'; }
cf_set_browser_check() { cf_call PATCH "/zones/$1/settings/browser_check" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

cf_get_bot_management() { cf_call_raw GET "/zones/$1/bot_management" | jq '.result // {}'; }

cf_set_bot_fight_off() {
    local zone_id="$1"
    cf_call_raw PUT "/zones/${zone_id}/bot_management" "$(jq -n '{
        enable_js: false,
        sbfm_likely_automated: "allow",
        sbfm_definitely_automated: "allow",
        sbfm_verified_bots: "allow",
        sbfm_static_resource_protection: false
    }')" | jq -e '.success' &>/dev/null
}

cf_restore_bot_management() {
    local zone_id="$1" backup="$2"
    local payload
    payload=$(echo "$backup" | jq '{
        enable_js: .enable_js,
        sbfm_likely_automated: .sbfm_likely_automated,
        sbfm_definitely_automated: .sbfm_definitely_automated,
        sbfm_verified_bots: .sbfm_verified_bots,
        sbfm_static_resource_protection: .sbfm_static_resource_protection
    }')
    cf_call_raw PUT "/zones/${zone_id}/bot_management" "$payload" | jq -e '.success' &>/dev/null
}

cf_relax_security() {
    local zone_id="$1"
    local sec_level browser_check bot_mgmt
    sec_level=$(cf_get_security_level "$zone_id")
    browser_check=$(cf_get_browser_check "$zone_id")
    bot_mgmt=$(cf_get_bot_management "$zone_id")

    if [[ "$sec_level" != "essentially_off" ]]; then
        cf_set_security_level "$zone_id" "essentially_off"
        ok "Security Level: essentially_off"
    fi
    if [[ "$browser_check" != "off" ]]; then
        cf_set_browser_check "$zone_id" "off"
        ok "Browser Check: off"
    fi
    local sbfm_likely
    sbfm_likely=$(echo "$bot_mgmt" | jq -r '.sbfm_likely_automated // ""')
    if [[ "$sbfm_likely" != "allow" ]]; then
        cf_set_bot_fight_off "$zone_id"
        ok "Bot Fight Mode: 已关闭"
    fi
    jq -n --arg sl "$sec_level" --arg bc "$browser_check" --argjson bm "$bot_mgmt" \
        '{security_level:$sl, browser_check:$bc, bot_management:$bm}'
}

cf_restore_security() {
    local zone_id="$1" backup="$2"
    [[ -z "$backup" || "$backup" == "null" ]] && return
    local sl bc bm
    sl=$(echo "$backup" | jq -r '.security_level // ""')
    bc=$(echo "$backup" | jq -r '.browser_check // ""')
    bm=$(echo "$backup" | jq '.bot_management // null')
    [[ -n "$sl" ]] && cf_set_security_level "$zone_id" "$sl" && ok "Security Level 已恢复: $sl"
    [[ -n "$bc" ]] && cf_set_browser_check "$zone_id" "$bc" && ok "Browser Check 已恢复: $bc"
    [[ "$bm" != "null" ]] && cf_restore_bot_management "$zone_id" "$bm" && ok "Bot Fight Mode 已恢复"
}

# ── CF Origin Rules ───────────────────────────────────
cf_get_origin_rules() {
    local r
    r=$(cf_call_raw GET "/zones/$1/rulesets/phases/http_request_origin/entrypoint")
    echo "$r" | jq -r 'if .success then .result.rules // [] else [] end' 2>/dev/null || echo '[]'
}

cf_put_origin_rules() {
    local r
    r=$(cf_call_raw PUT "/zones/$1/rulesets/phases/http_request_origin/entrypoint" \
        "$(jq -n --argjson r "$2" '{rules:$r}')")
    echo "$r" | jq -e '.success' &>/dev/null || die "Origin Rules 写入失败: $(echo "$r" | jq -c '.errors')"
}

build_origin_rule() {
    local domain="$1" ext_port="$2" path="$3"
    jq -n --arg d "$domain" --argjson p "$((ext_port))" --arg pa "$path" --arg pfx "$MANAGED_PREFIX" '{
        description: ($pfx + "vless " + $pa),
        enabled: true,
        expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + $pa + "\")"),
        action: "route",
        action_parameters: { origin: { port: $p } }
    }'
}

apply_origin_rules() {
    local zone_id="$1" domain="$2" ext_port="$3" path="$4"
    local existing kept new_rule merged
    existing=$(cf_get_origin_rules "$zone_id")
    # 保留非本脚本管理的规则
    kept=$(echo "$existing" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | select(
            (.description | startswith($pfx) | not) or
            (.expression | ascii_downcase | contains("http.host eq \"" + ($d|ascii_downcase) + "\"") | not)
        )
    ]')
    new_rule=$(build_origin_rule "$domain" "$ext_port" "$path")
    merged=$(jq -n --argjson a "$kept" --argjson b "$new_rule" '$a + [$b]')
    cf_put_origin_rules "$zone_id" "$merged"
}

# ── sing-box 安装 ─────────────────────────────────────
install_sb() {
    [[ -f "$SB_BINARY" ]] && { ok "sing-box 已安装: $($SB_BINARY version | head -1)"; return; }

    info "检测 CPU 架构..."
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*) arch="armv7" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac

    # 版本号获取失败不致命（GitHub API 限流）
    local ver=""
    ver=$(curl -sf "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null) || true
    if [[ -n "$ver" && "$ver" != "null" ]]; then
        local ver_num="${ver#v}"
        info "sing-box $ver ($arch)"
        local dl_url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver_num}-linux-${arch}.tar.gz"
    else
        warn "GitHub API 限流，使用固定版本 v1.8.11"
        ver="v1.8.11"; ver_num="1.8.11"
        local dl_url="https://github.com/SagerNet/sing-box/releases/download/v1.8.11/sing-box-1.8.11-linux-${arch}.tar.gz"
    fi

    local tmp="/tmp/sb-install-$$"
    mkdir -p "$tmp"
    info "下载中..."
    curl -fsSL -o "$tmp/sb.tar.gz" "$dl_url" || die "下载失败"
    tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || die "解压失败"

    mkdir -p /usr/local/bin
    local extracted
    extracted=$(find "$tmp" -name sing-box -type f | head -1)
    [[ -n "$extracted" ]] || die "解压后未找到 sing-box 二进制"
    mv "$extracted" "$SB_BINARY"
    chmod +x "$SB_BINARY"
    rm -rf "$tmp"

    # Alpine musl 兼容检测
    if ! "$SB_BINARY" version >/dev/null 2>&1; then
        if command -v apk &>/dev/null; then
            warn "sing-box 无法执行，安装 glibc 兼容层..."
            apk add --no-cache gcompat libc6-compat
            ln -sf /lib/libc.musl-aarch64.so.1 /lib/ld-linux-aarch64.so.1 2>/dev/null || true
            ln -sf /lib/libc.musl-x86_64.so.1 /lib/ld-linux-x86-64.so.2 2>/dev/null || true
            "$SB_BINARY" version >/dev/null 2>&1 || die "兼容层安装后仍无法运行"
            ok "glibc 兼容层已安装"
        else
            die "sing-box 无法执行，请检查系统依赖"
        fi
    fi

    ok "sing-box 安装完成: $($SB_BINARY version | head -1)"
}

# ── sing-box 配置生成 ─────────────────────────────────
gen_sb_config() {
    local uuid="$1" listen_port="$2" path="$3"
    jq -n --arg uid "$uuid" --argjson lp "$((listen_port))" --arg pa "$path" '{
        log: { level: "warn", timestamp: true, output: "/var/log/sing-box.log" },
        inbounds: [{
            type: "vless",
            tag: "vless-ws-in",
            listen: "::",
            listen_port: $lp,
            users: [{ name: "user1", uuid: $uid }],
            transport: { type: "ws", path: $pa }
        }],
        outbounds: [{ type: "direct", tag: "direct" }]
    }'
}

write_sb_config() {
    mkdir -p "$SB_CONFIG_DIR"
    echo "$1" > "$SB_CONFIG_PATH"
    chmod 644 "$SB_CONFIG_PATH"
    # 配置校验
    "$SB_BINARY" check -c "$SB_CONFIG_PATH" >/dev/null 2>&1 || die "配置校验失败，请检查: $SB_CONFIG_PATH"
    ok "配置已写入并校验通过"
}

# ── 节点链接生成 ──────────────────────────────────────
build_vless_link() {
    local uuid="$1" domain="$2" path="$3"
    echo "vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=$(urlencode "$path")#SB-CF-Lite"
}

save_links_snapshot() {
    local domain="$1" uuid="$2" path="$3" link="$4"
    { echo "域名: $domain"; echo "UUID: $uuid"; echo "WS路径: $path"; echo; echo "VLESS: $link"; } > "$LAST_LINKS_PATH"
    chmod 600 "$LAST_LINKS_PATH"
}

# ── 状态管理 ──────────────────────────────────────────
load_state() { [[ -f "$STATE_PATH" ]] && cat "$STATE_PATH"; }
save_state() { mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"; echo "$1" > "$STATE_PATH"; chmod 600 "$STATE_PATH"; }
remove_state() { rm -f "$STATE_PATH"; }

# ── 1. 安装 ──────────────────────────────────────────
do_install() {
    local state
    state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] && die "检测到上次配置($(echo "$state" | jq -r '.domain // "?"'))，请先卸载"

    install_sb

    local net_mode
    net_mode=$(prompt_net_mode "$(detect_nat)")
    ok "网络模式: $(net_mode_label "$net_mode")"

    prompt_cf

    # 域名
    local domain zone_id
    while true; do
        read -rp "绑定域名 (例如 node.yourdomain.com): " domain || die "输入已中断"
        [[ -z "$domain" ]] && { warn "域名不能为空"; continue; }
        if zone_id=$(cf_find_zone "$domain"); then
            info "匹配到 Zone: $zone_id"
            break
        fi
        warn "无法匹配 Zone: $domain，请确认域名已托管并重输"
    done

    # 端口
    local listen_port ext_port
    if [[ "$net_mode" == "nat" ]]; then
        read -rp "内部监听端口 (默认 8080): " listen_port
        listen_port=${listen_port:-8080}
        read -rp "外部映射端口 (NAT 面板给的公网端口): " ext_port
        [[ -z "$ext_port" ]] && die "外部端口不能为空"
    else
        read -rp "监听端口 (默认 8080): " listen_port
        listen_port=${listen_port:-8080}
        ext_port="$listen_port"
    fi
    [[ "$listen_port" =~ ^[0-9]+$ ]] || die "无效端口: $listen_port"
    [[ "$ext_port" =~ ^[0-9]+$ ]] || die "无效端口: $ext_port"

    # UUID 和路径
    local uuid path
    read -rp "UUID (留空=自动生成): " custom_uuid
    if [[ -n "$custom_uuid" ]]; then
        [[ "$custom_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
        uuid="${custom_uuid,,}"
    else
        uuid=$(gen_uuid)
    fi
    path=$(gen_path)

    # 预览
    echo
    echo "====== 配置预览 ======"
    echo "  域名:     $domain"
    echo "  UUID:     $uuid"
    echo "  WS路径:   $path"
    echo "  模式:     $net_mode"
    echo "  监听端口: $listen_port"
    echo "  外部端口: $ext_port"
    echo "======================="
    echo
    read -rp "确认部署? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    # 写入配置并启动
    local config
    config=$(gen_sb_config "$uuid" "$listen_port" "$path")
    write_sb_config "$config"
    [[ "$INIT_SYSTEM" == "openrc" && ! -f "$SB_OPENRC_SCRIPT" ]] && write_openrc_script && ok "OpenRC 服务脚本已创建"
    restart_sb

    # CF 配置
    local public_ip dns_before ssl_before origin_before dns_record_id security_backup
    public_ip=$(get_public_ip)
    dns_before=$(cf_get_dns "$zone_id" "$domain" || echo "null")
    [[ "$dns_before" == "" ]] && dns_before="null"
    ssl_before=$(cf_get_ssl "$zone_id")
    origin_before=$(cf_get_origin_rules "$zone_id")

    dns_record_id=$(cf_upsert_dns "$zone_id" "$domain" "$public_ip")
    ok "DNS A 记录: $domain -> $public_ip (已代理)"

    cf_set_ssl "$zone_id" "flexible"
    ok "SSL 模式: flexible"

    apply_origin_rules "$zone_id" "$domain" "$ext_port" "$path"
    ok "Origin Rules: 端口 $ext_port"

    security_backup=$(cf_relax_security "$zone_id")

    # 生成链接
    local link
    link=$(build_vless_link "$uuid" "$domain" "$path")
    save_links_snapshot "$domain" "$uuid" "$path" "$link"

    # 保存状态（兜底空值）
    [[ -n "$dns_before" ]] || dns_before="null"
    [[ -n "$origin_before" ]] || origin_before="[]"
    [[ -n "$security_backup" ]] || security_backup="null"

    local dns_existed="false"
    [[ "$dns_before" != "null" ]] && dns_existed="true"

    save_state "$(jq -n \
        --arg d "$domain" --arg z "$zone_id" --arg u "$uuid" --arg pa "$path" --arg mode "$net_mode" \
        --argjson lp "$((listen_port))" --argjson ep "$((ext_port))" \
        --arg drid "$dns_record_id" --argjson dex "$dns_existed" --argjson drec "$dns_before" \
        --arg ssl "$ssl_before" --argjson orbk "$origin_before" --argjson secbk "$security_backup" \
        --arg link "$link" \
        '{domain:$d, zone_id:$z, uuid:$u, path:$pa, net_mode:$mode,
          listen_port:$lp, ext_port:$ep,
          managed_dns_record_id:$drid, dns_backup:{existed:$dex, record:$drec},
          ssl_backup:$ssl, origin_rules_backup:$orbk, security_backup:$secbk, link:$link}')"

    echo
    ok "部署完成！"
    echo
    echo "  VLESS 节点链接:"
    echo "  $link"
    echo
    echo "  链接已保存到: $LAST_LINKS_PATH"
}

# ── 2. 卸载 ──────────────────────────────────────────
do_uninstall() {
    local state
    state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到上次配置"

    local domain; domain=$(echo "$state" | jq -r '.domain')
    echo "正在卸载: $domain"

    svc_stop; rm -f "$SB_CONFIG_PATH"
    ok "sing-box 已停止"

    if load_cf_account; then
        local zone_id; zone_id=$(echo "$state" | jq -r '.zone_id // ""')
        if [[ -n "$zone_id" ]]; then
            # 恢复 Origin Rules
            cf_put_origin_rules "$zone_id" "$(echo "$state" | jq '.origin_rules_backup // []')"
            ok "Origin Rules 已恢复"

            # 恢复 SSL
            local ssl_bk; ssl_bk=$(echo "$state" | jq -r '.ssl_backup // ""')
            [[ -n "$ssl_bk" ]] && cf_set_ssl "$zone_id" "$ssl_bk" && ok "SSL 已恢复: $ssl_bk"

            # 恢复 DNS
            local dns_existed record_id
            dns_existed=$(echo "$state" | jq -r '.dns_backup.existed')
            record_id=$(echo "$state" | jq -r '.managed_dns_record_id // ""')
            if [[ "$dns_existed" == "true" ]]; then
                local rp
                rp=$(echo "$state" | jq '.dns_backup.record | {type:(.type//"A"),name:(.name//""),content:(.content//""),proxied:(.proxied//false),ttl:(.ttl//1)}')
                cf_call PUT "/zones/${zone_id}/dns_records/${record_id}" "$rp" >/dev/null
                ok "DNS 已恢复"
            elif [[ -n "$record_id" ]]; then
                cf_call_raw DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null 2>&1 || true
                ok "DNS 已删除"
            fi

            # 恢复安全规则
            local sec_bk; sec_bk=$(echo "$state" | jq '.security_backup // null')
            cf_restore_security "$zone_id" "$sec_bk"
        fi
    else
        warn "无 CF 凭据，跳过 CF 配置恢复"
    fi

    remove_state
    rm -f "$LAST_LINKS_PATH" "$CF_ACCOUNT_PATH"
    ok "已清理状态和凭据"
    ok "卸载完成"
}

# ── 3. 查看订阅 ──────────────────────────────────────
do_show() {
    if [[ -f "$LAST_LINKS_PATH" ]]; then
        cat "$LAST_LINKS_PATH"
        return
    fi
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "无历史配置"
    echo "域名: $(echo "$state" | jq -r '.domain')"
    echo "UUID: $(echo "$state" | jq -r '.uuid')"
    echo "WS路径: $(echo "$state" | jq -r '.path')"
    echo
    echo "$(echo "$state" | jq -r '.link')"
}

# ── 4. 修改配置 ──────────────────────────────────────
do_modify() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain uuid path listen_port ext_port net_mode zone_id
    domain=$(echo "$state" | jq -r '.domain')
    uuid=$(echo "$state" | jq -r '.uuid')
    path=$(echo "$state" | jq -r '.path')
    listen_port=$(echo "$state" | jq -r '.listen_port')
    ext_port=$(echo "$state" | jq -r '.ext_port')
    net_mode=$(echo "$state" | jq -r '.net_mode')
    zone_id=$(echo "$state" | jq -r '.zone_id')

    echo
    echo "当前配置 ($net_mode):"
    echo "  域名:     $domain"
    echo "  UUID:     $uuid"
    echo "  WS路径:   $path"
    echo "  监听端口: $listen_port"
    echo "  外部端口: $ext_port"
    echo
    echo "  1. 修改 UUID"
    echo "  2. 修改端口"
    echo "  3. 修改 WS 路径"
    echo "  4. 全部修改"
    echo "  0. 返回"
    echo
    read -rp "请选择 [0-4]: " mc
    [[ "$mc" =~ ^[0-4]$ ]] || die "无效选项"
    [[ "$mc" == "0" ]] && return

    local new_uuid="$uuid" new_path="$path" new_listen="$listen_port" new_ext="$ext_port" changed=false

    if [[ "$mc" == "1" || "$mc" == "4" ]]; then
        read -rp "新 UUID (留空=重新生成): " iu
        if [[ -n "$iu" ]]; then
            [[ "$iu" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
            new_uuid="${iu,,}"
        else
            new_uuid=$(gen_uuid)
        fi
        changed=true; ok "UUID: $new_uuid"
    fi

    if [[ "$mc" == "2" || "$mc" == "4" ]]; then
        if [[ "$net_mode" == "nat" ]]; then
            read -rp "新内部监听端口 (当前=$listen_port, 回车=不改): " nl
            [[ -n "$nl" ]] && { [[ "$nl" =~ ^[0-9]+$ ]] || die "无效端口"; new_listen="$nl"; changed=true; }
            read -rp "新外部映射端口 (当前=$ext_port, 回车=不改): " ne
            [[ -n "$ne" ]] && { [[ "$ne" =~ ^[0-9]+$ ]] || die "无效端口"; new_ext="$ne"; changed=true; }
        else
            read -rp "新端口 (当前=$listen_port, 回车=不改): " np
            if [[ -n "$np" ]]; then
                [[ "$np" =~ ^[0-9]+$ ]] || die "无效端口"
                new_listen="$np"; new_ext="$np"; changed=true
            fi
        fi
    fi

    if [[ "$mc" == "3" || "$mc" == "4" ]]; then
        read -rp "新 WS 路径 (当前=$path, 留空=随机生成, 输入=自定义): " np
        if [[ -n "$np" ]]; then
            [[ "$np" == /* ]] || np="/$np"
            new_path="$np"
        else
            new_path=$(gen_path)
        fi
        changed=true; ok "WS路径: $new_path"
    fi

    [[ "$changed" == "true" ]] || { echo "无修改"; return; }

    # 应用修改
    write_sb_config "$(gen_sb_config "$new_uuid" "$new_listen" "$new_path")"
    restart_sb

    load_cf_account || die "未找到 CF 凭据"
    apply_origin_rules "$zone_id" "$domain" "$new_ext" "$new_path"
    ok "Origin Rules 已更新"

    # DNS IP 可能变了
    local public_ip current_ip
    public_ip=$(get_public_ip)
    current_ip=$(cf_get_dns "$zone_id" "$domain" | jq -r '.content // ""')
    [[ "$current_ip" != "$public_ip" ]] && cf_upsert_dns "$zone_id" "$domain" "$public_ip" >/dev/null && ok "DNS IP 已更新: $public_ip"

    local link
    link=$(build_vless_link "$new_uuid" "$domain" "$new_path")
    save_links_snapshot "$domain" "$new_uuid" "$new_path" "$link"

    save_state "$(echo "$state" | jq \
        --arg u "$new_uuid" --arg pa "$new_path" \
        --argjson lp "$((new_listen))" --argjson ep "$((new_ext))" \
        --arg link "$link" \
        '.uuid=$u | .path=$pa | .listen_port=$lp | .ext_port=$ep | .link=$link')"

    echo; ok "配置已更新"
    echo "  $link"
}

# ── 5. 查看当前配置 ──────────────────────────────────
do_show_config() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    echo
    echo "  域名:     $(echo "$state" | jq -r '.domain')"
    echo "  UUID:     $(echo "$state" | jq -r '.uuid')"
    echo "  WS路径:   $(echo "$state" | jq -r '.path')"
    echo "  模式:     $(net_mode_label "$(echo "$state" | jq -r '.net_mode')")"
    echo "  监听端口: $(echo "$state" | jq -r '.listen_port')"
    echo "  外部端口: $(echo "$state" | jq -r '.ext_port')"
    echo -n "  服务:     "; svc_is_active && echo "运行中" || echo "未运行"
    echo
    echo "  节点链接:"
    echo "  $(echo "$state" | jq -r '.link')"
    echo
}

# ── 6. 更新外部端口 (NAT 快捷) ───────────────────────
do_update_ext_port() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    local net_mode; net_mode=$(echo "$state" | jq -r '.net_mode')
    [[ "$net_mode" == "nat" ]] || die "当前是直连模式，无需单独更新外部端口，请用 [4.修改配置]"

    local domain ext_port zone_id
    domain=$(echo "$state" | jq -r '.domain')
    ext_port=$(echo "$state" | jq -r '.ext_port')
    zone_id=$(echo "$state" | jq -r '.zone_id')

    echo "当前外部端口: $ext_port"
    read -rp "新外部端口: " ne
    [[ -n "$ne" ]] || die "不能为空"
    [[ "$ne" =~ ^[0-9]+$ ]] || die "无效端口"

    load_cf_account || die "未找到 CF 凭据"
    local path; path=$(echo "$state" | jq -r '.path')
    apply_origin_rules "$zone_id" "$domain" "$ne" "$path"
    ok "Origin Rules 已更新: 端口 $ne"

    save_state "$(echo "$state" | jq --argjson ep "$((ne))" '.ext_port=$ep')"
    ok "外部端口已更新为 $ne"
}

# ── 7. 重启 sing-box ─────────────────────────────────
do_restart() {
    svc_is_active && echo "正在重启 sing-box..." || echo "sing-box 未运行，正在启动..."
    restart_sb
}

# ── 8. 切换网络模式 ──────────────────────────────────
do_switch_net_mode() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain zone_id uuid cur listen_port path
    domain=$(echo "$state" | jq -r '.domain')
    zone_id=$(echo "$state" | jq -r '.zone_id')
    uuid=$(echo "$state" | jq -r '.uuid')
    cur=$(echo "$state" | jq -r '.net_mode')
    listen_port=$(echo "$state" | jq -r '.listen_port')
    path=$(echo "$state" | jq -r '.path')

    echo "当前模式: $(net_mode_label "$cur")"
    local target
    if [[ "$cur" == "nat" ]]; then
        target="direct"
        echo "切成直连后，外部端口=监听端口 ($listen_port)"
    else
        target="nat"
        echo "切成 NAT 后，需要指定外部端口（NAT 面板映射到 $listen_port）"
        read -rp "外部映射端口: " ne
        [[ "$ne" =~ ^[0-9]+$ ]] || die "无效端口"
    fi
    read -rp "确认切换到 $(net_mode_label "$target")? (y/N): " c
    [[ "${c,,}" =~ ^(y|yes)$ ]] || die "已取消"

    local new_ext
    if [[ "$target" == "direct" ]]; then
        new_ext="$listen_port"
    else
        new_ext="$ne"
    fi

    load_cf_account || die "未找到 CF 凭据"
    apply_origin_rules "$zone_id" "$domain" "$new_ext" "$path"
    ok "Origin Rules 已更新"

    save_state "$(echo "$state" | jq --arg m "$target" --argjson ep "$((new_ext))" '.net_mode=$m | .ext_port=$ep')"
    ok "已切换到 $(net_mode_label "$target")"
}

# ── 快捷入口 ──────────────────────────────────────────
ensure_shortcut() {
    local target="/usr/local/bin/sb"
    # 每次都覆盖，避免旧版本残留导致 sb 无响应
    cat > "$target" << 'SCEOF'
#!/bin/bash
# sing-box CF Lite 快捷入口
SCRIPT="/etc/sb-cf-lite/sb-cf-lite.sh"
if [ -f "$SCRIPT" ]; then
    exec bash "$SCRIPT" "$@"
else
    echo "脚本未找到: $SCRIPT"
    echo "请重新运行安装脚本"
    exit 1
fi
SCEOF
    chmod +x "$target"
}

# 把自身复制到状态目录，供快捷入口调用
self_install() {
    mkdir -p "$STATE_DIR"
    local src="${BASH_SOURCE[0]}"
    if [ -f "$src" ]; then
        cp "$src" "$STATE_DIR/sb-cf-lite.sh" 2>/dev/null && ok "快捷入口已安装: sb" || warn "自复制失败，sb 命令可能不可用"
    fi
}

# ── 主入口 ────────────────────────────────────────────
main() {
    [[ "$(id -u)" == "0" ]] || die "请使用 root 运行此脚本"
    detect_init
    install_deps
    need_cmd curl; need_cmd jq
    self_install
    ensure_shortcut

    local state current_domain="" net_mode=""
    state=$(load_state 2>/dev/null || true)
    if [[ -n "$state" ]]; then
        current_domain=$(echo "$state" | jq -r '.domain // ""')
        net_mode=$(echo "$state" | jq -r '.net_mode // ""')
    fi

    echo
    echo "  sing-box CF Lite ($INIT_SYSTEM) — 64M NAT 优化版"
    echo
    echo "  1. 安装节点"
    echo "  2. 卸载"
    echo "  3. 查看订阅"
    echo "  4. 修改配置 (UUID/端口/路径)"
    echo "  5. 查看当前配置"
    echo "  6. 更新外部端口 (NAT换端口)"
    echo "  7. 重启 sing-box"
    echo "  8. 切换网络模式 (直连/NAT)"
    [[ -n "$current_domain" ]] && echo "     (当前: $current_domain${net_mode:+ [$net_mode]})"
    echo
    read -rp "请选择 [1-8]: " choice
    case "$choice" in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_show ;;
        4) do_modify ;;
        5) do_show_config ;;
        6) do_update_ext_port ;;
        7) do_restart ;;
        8) do_switch_net_mode ;;
        *) die "无效选项: $choice" ;;
    esac
}

main "$@"
