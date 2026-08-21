#!/usr/bin/env bash
set -euo pipefail
# ==========================================
# 项目: sing-box CF Lite (NAT 小鸡优化版)
# 协议: VLESS / Trojan / VMess (共享域名, 路径区分)
# 适配: Alpine (OpenRC) / Debian (Systemd)
# 一键: wget -qO /root/sb.sh "URL" && bash /root/sb.sh
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

# 协议元数据
declare -A PROTO_SUFFIX=([vless]="vl" [trojan]="tr" [vmess]="vm")
declare -A PROTO_LABEL=([vless]="VLESS" [trojan]="TROJAN" [vmess]="VMESS")

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
gen_path() { echo "/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 6 | head -n 1)"; }

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
    command -v openssl &>/dev/null || missing+=(openssl)
    command -v tar   &>/dev/null || missing+=(tar)
    [[ ${#missing[@]} -eq 0 ]] && return
    info "安装依赖: ${missing[*]}"
    if command -v apk &>/dev/null; then
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
    checkpath -f -m 0644 /var/log/sing-box.log
}
INITEOF
    chmod +x "$SB_OPENRC_SCRIPT"
}

svc_enable() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl enable sing-box &>/dev/null
    else rc-update add sing-box default &>/dev/null; fi
    true
}
svc_start() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart sing-box
    else [[ -f "$SB_OPENRC_SCRIPT" ]] || write_openrc_script; rc-service sing-box restart; fi
}
svc_stop() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl stop sing-box &>/dev/null; systemctl disable sing-box &>/dev/null
    else rc-service sing-box stop &>/dev/null; rc-update del sing-box default &>/dev/null; fi
    true
}
svc_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active sing-box &>/dev/null
    else rc-service sing-box status &>/dev/null 2>&1; fi
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
    svc_start || die "sing-box 重启失败，日志: tail -20 $SB_LOG"
    sleep 2
    svc_is_active || die "sing-box 未正常启动，日志: tail -20 $SB_LOG"
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
    local public_ip; public_ip=$(get_public_ip)
    ip addr show 2>/dev/null | grep -qE "inet ${public_ip}/" && echo "direct" || echo "nat"
}

net_mode_label() {
    [[ "$1" == "direct" ]] && echo "直连" || echo "NAT"
}

prompt_net_mode() {
    local detected="$1" ans
    echo >&2
    info "网络环境探测: $(net_mode_label "$detected")" >&2
    read -rp "模式确认 (1=直连, 2=NAT, 回车=探测结果): " ans
    case "$ans" in 1) echo "direct" ;; 2) echo "nat" ;; "") echo "$detected" ;; *) die "无效选项" ;; esac
}

get_listening_ports() {
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' '
}

rand_port() {
    local existing="$1" p
    while true; do
        p=$(( RANDOM % 50000 + 10000 ))
        echo "$existing" | grep -qw "$p" || { echo "$p"; return; }
    done
}

# ── CF API ────────────────────────────────────────────
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

# ── CF 凭据 ───────────────────────────────────────────
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
        read -rp "复用 CF 凭据 ($CF_EMAIL, Key=$masked)? (Y/n): " ans
        if [[ "${ans,,}" =~ ^(|y|yes)$ ]]; then
            cf_verify_credentials && return 0
            warn "已保存凭据校验失败，请重输"
        fi
    fi
    while true; do
        read -rp "Cloudflare 邮箱: " CF_EMAIL || die "输入中断"
        read -rsp "Cloudflare Global API Key: " CF_KEY || die "输入中断"; echo
        [[ -z "$CF_EMAIL" || -z "$CF_KEY" ]] && { warn "不能为空"; continue; }
        echo -n "校验中... "
        if cf_verify_credentials; then
            echo "通过"; save_cf_account; return 0
        fi
        warn "失败：邮箱或 Global API Key 错误（不是 API Token）"
    done
}

# ── CF Zone / DNS / SSL ───────────────────────────────
cf_find_zone() {
    local domain="$1" zones best_name="" best_id=""
    zones=$(cf_call GET "/zones?per_page=100" | jq -r '.result[] | "\(.name) \(.id)"')
    while IFS=' ' read -r zname zid; do
        if [[ "$domain" == "$zname" || "$domain" == *".$zname" ]]; then
            [[ ${#zname} -gt ${#best_name} ]] && best_name="$zname" && best_id="$zid"
        fi
    done <<< "$zones"
    [[ -n "$best_id" ]] || return 1
    echo "$best_id"
}

cf_get_dns() { cf_call GET "/zones/$1/dns_records?type=A&name=$2" | jq '.result[0] // empty'; }

cf_upsert_dns() {
    local zone_id="$1" domain="$2" ip="$3" payload existing
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

# ── CF 安全规则 ───────────────────────────────────────
cf_get_security_level() { cf_call GET "/zones/$1/settings/security_level" | jq -r '.result.value'; }
cf_set_security_level() { cf_call PATCH "/zones/$1/settings/security_level" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }
cf_get_browser_check() { cf_call GET "/zones/$1/settings/browser_check" | jq -r '.result.value'; }
cf_set_browser_check() { cf_call PATCH "/zones/$1/settings/browser_check" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }
cf_get_bot_management() { cf_call_raw GET "/zones/$1/bot_management" | jq '.result // {}'; }

cf_set_bot_fight_off() {
    cf_call_raw PUT "/zones/$1/bot_management" "$(jq -n '{
        enable_js:false, sbfm_likely_automated:"allow", sbfm_definitely_automated:"allow",
        sbfm_verified_bots:"allow", sbfm_static_resource_protection:false
    }')" | jq -e '.success' &>/dev/null
}

cf_restore_bot_management() {
    local payload; payload=$(echo "$2" | jq '{
        enable_js:.enable_js, sbfm_likely_automated:.sbfm_likely_automated,
        sbfm_definitely_automated:.sbfm_definitely_automated, sbfm_verified_bots:.sbfm_verified_bots,
        sbfm_static_resource_protection:.sbfm_static_resource_protection
    }')
    cf_call_raw PUT "/zones/$1/bot_management" "$payload" | jq -e '.success' &>/dev/null
}

cf_relax_security() {
    local zone_id="$1" sec_level browser_check bot_mgmt
    sec_level=$(cf_get_security_level "$zone_id")
    browser_check=$(cf_get_browser_check "$zone_id")
    bot_mgmt=$(cf_get_bot_management "$zone_id")
    [[ "$sec_level" != "essentially_off" ]] && cf_set_security_level "$zone_id" "essentially_off" && ok "Security Level: off"
    [[ "$browser_check" != "off" ]] && cf_set_browser_check "$zone_id" "off" && ok "Browser Check: off"
    local sbfm; sbfm=$(echo "$bot_mgmt" | jq -r '.sbfm_likely_automated // ""')
    [[ "$sbfm" != "allow" ]] && cf_set_bot_fight_off "$zone_id" && ok "Bot Fight: off"
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
    [[ -n "$sl" ]] && cf_set_security_level "$zone_id" "$sl" && ok "Security Level 恢复: $sl"
    [[ -n "$bc" ]] && cf_set_browser_check "$zone_id" "$bc" && ok "Browser Check 恢复"
    [[ "$bm" != "null" ]] && cf_restore_bot_management "$zone_id" "$bm" && ok "Bot Fight 恢复"
}

# ── CF Origin Rules (多协议, 按路径区分) ──────────────
cf_get_origin_rules() {
    local r; r=$(cf_call_raw GET "/zones/$1/rulesets/phases/http_request_origin/entrypoint")
    echo "$r" | jq -r 'if .success then .result.rules // [] else [] end' 2>/dev/null || echo '[]'
}

cf_put_origin_rules() {
    local r
    r=$(cf_call_raw PUT "/zones/$1/rulesets/phases/http_request_origin/entrypoint" \
        "$(jq -n --argjson r "$2" '{rules:$r}')")
    echo "$r" | jq -e '.success' &>/dev/null || die "Origin Rules 写入失败: $(echo "$r" | jq -c '.errors')"
}

build_origin_rules() {
    local domain="$1" routes_json="$2"
    echo "$routes_json" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | {
            description: ($pfx + .protocol + " " + .path),
            enabled: true,
            expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + .path + "\")"),
            action: "route",
            action_parameters: { origin: { port: .ext_port } }
        }
    ]'
}

apply_origin_rules() {
    local zone_id="$1" domain="$2" routes_json="$3"
    local existing kept new_managed merged
    existing=$(cf_get_origin_rules "$zone_id")
    kept=$(echo "$existing" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | select(
            (.description | startswith($pfx) | not) or
            (.expression | ascii_downcase | contains("http.host eq \"" + ($d|ascii_downcase) + "\"") | not)
        )
    ]')
    new_managed=$(build_origin_rules "$domain" "$routes_json")
    merged=$(jq -n --argjson a "$kept" --argjson b "$new_managed" '$a + $b')
    cf_put_origin_rules "$zone_id" "$merged"
}

# ── sing-box 安装 ─────────────────────────────────────
install_sb() {
    [[ -f "$SB_BINARY" ]] && { ok "sing-box 已安装: $($SB_BINARY version | head -1)"; return; }

    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*) arch="armv7" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac

    local ver="" dl_url
    ver=$(curl -sf "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null) || true
    if [[ -n "$ver" && "$ver" != "null" ]]; then
        local ver_num="${ver#v}"
        info "sing-box $ver ($arch)"
        dl_url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver_num}-linux-${arch}.tar.gz"
    else
        warn "GitHub API 限流，使用 v1.8.11"
        ver="v1.8.11"
        dl_url="https://github.com/SagerNet/sing-box/releases/download/v1.8.11/sing-box-1.8.11-linux-${arch}.tar.gz"
    fi

    local tmp="/tmp/sb-install-$$"
    mkdir -p "$tmp"
    info "下载中..."
    curl -fsSL -o "$tmp/sb.tar.gz" "$dl_url" || die "下载失败"
    tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || die "解压失败"
    mkdir -p /usr/local/bin
    local extracted; extracted=$(find "$tmp" -name sing-box -type f | head -1)
    [[ -n "$extracted" ]] || die "解压后未找到二进制"
    mv "$extracted" "$SB_BINARY"; chmod +x "$SB_BINARY"
    rm -rf "$tmp"

    # Alpine musl 兼容
    if ! "$SB_BINARY" version >/dev/null 2>&1; then
        if command -v apk &>/dev/null; then
            warn "安装 glibc 兼容层..."
            apk add --no-cache gcompat libc6-compat
            ln -sf /lib/libc.musl-aarch64.so.1 /lib/ld-linux-aarch64.so.1 2>/dev/null || true
            ln -sf /lib/libc.musl-x86_64.so.1 /lib/ld-linux-x86-64.so.2 2>/dev/null || true
            "$SB_BINARY" version >/dev/null 2>&1 || die "兼容层安装后仍无法运行"
            ok "glibc 兼容层已安装"
        else
            die "sing-box 无法执行"
        fi
    fi
    ok "sing-box 安装完成: $($SB_BINARY version | head -1)"
}

# ── 多协议配置生成 ────────────────────────────────────
# routes_json 格式: [{protocol, listen_port, ext_port, path}, ...]
gen_sb_config() {
    local uuid="$1" routes_json="$2"
    local inbounds
    inbounds=$(echo "$routes_json" | jq --arg uid "$uuid" '[
        .[] | {
            tag: ("in-" + .protocol + "-" + (.listen_port|tostring)),
            type: .protocol,
            listen: "::",
            listen_port: .listen_port,
            users: (
                if .protocol == "trojan" then [{name:"user1", password:$uid}]
                elif .protocol == "vmess" then [{name:"user1", uuid:$uid, alterId:0}]
                else [{name:"user1", uuid:$uid}]
                end
            ),
            transport: { type: "ws", path: .path }
        }
    ]')
    jq -n --argjson inb "$inbounds" '{
        log:{level:"warn", timestamp:true, output:"/var/log/sing-box.log"},
        inbounds:$inb,
        outbounds:[{type:"direct", tag:"direct"}]
    }'
}

write_sb_config() {
    mkdir -p "$SB_CONFIG_DIR"
    echo "$1" > "$SB_CONFIG_PATH"
    chmod 644 "$SB_CONFIG_PATH"
    "$SB_BINARY" check -c "$SB_CONFIG_PATH" >/dev/null 2>&1 || die "配置校验失败: $SB_CONFIG_PATH"
    ok "配置已写入并校验通过"
}

# ── 多协议链接生成 ────────────────────────────────────
build_vless_link() {
    local uuid="$1" domain="$2" path="$3"
    echo "vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=$(urlencode "$path")#SB-CF-Lite-VLESS"
}

build_trojan_link() {
    local password="$1" domain="$2" path="$3"
    echo "trojan://${password}@${domain}:443?security=tls&sni=${domain}&type=ws&host=${domain}&path=$(urlencode "$path")#SB-CF-Lite-TROJAN"
}

build_vmess_link() {
    local uuid="$1" domain="$2" path="$3"
    local json
    json=$(jq -n --arg u "$uuid" --arg d "$domain" --arg p "$path" '{
        v:"2", ps:"SB-CF-Lite-VMESS", add:$d, port:"443", id:$u, aid:"0",
        scy:"auto", net:"ws", type:"none", host:$d, path:$p, tls:"tls", sni:$d
    }')
    echo "vmess://$(echo -n "$json" | base64 -w0)"
}

gen_all_links() {
    local uuid="$1" domain="$2" routes_json="$3"
    local links_json='{}' proto path link
    while IFS=$'\t' read -r proto path; do
        case "$proto" in
            vless) link=$(build_vless_link "$uuid" "$domain" "$path") ;;
            trojan) link=$(build_trojan_link "$uuid" "$domain" "$path") ;;
            vmess) link=$(build_vmess_link "$uuid" "$domain" "$path") ;;
        esac
        links_json=$(echo "$links_json" | jq --arg p "$proto" --arg l "$link" '. + {($p):$l}')
    done < <(echo "$routes_json" | jq -r '.[] | [.protocol, .path] | @tsv')
    echo "$links_json"
}

save_links_snapshot() {
    local domain="$1" uuid="$2" links_json="$3"
    { echo "域名: $domain"; echo "UUID/密码: $uuid"; echo
      echo "$links_json" | jq -r 'to_entries[] | "\(.key | ascii_upcase): \(.value)"'
    } > "$LAST_LINKS_PATH"
    chmod 600 "$LAST_LINKS_PATH"
}

print_links() {
    local links_json="$1"
    echo "$links_json" | jq -r 'to_entries[] | "  \(.key | ascii_upcase): \(.value)"'
}

# ── 状态管理 ──────────────────────────────────────────
load_state() { [[ -f "$STATE_PATH" ]] && cat "$STATE_PATH"; }
save_state() { mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"; echo "$1" > "$STATE_PATH"; chmod 600 "$STATE_PATH"; }
remove_state() { rm -f "$STATE_PATH"; }

# ── 协议选择与端口配置 ────────────────────────────────
prompt_protocols() {
    read -rp "协议 (1=vless,2=trojan,3=vmess，逗号分隔，留空=全部): " proto_raw
    local protocols=()
    if [[ -z "$proto_raw" ]]; then
        protocols=(vless trojan vmess)
    else
        local -A pmap=([1]=vless [2]=trojan [3]=vmess [vless]=vless [trojan]=trojan [vmess]=vmess)
        IFS=',' read -ra tokens <<< "$proto_raw"
        for t in "${tokens[@]}"; do
            t="${t,,}"; t="${t// /}"
            [[ -n "${pmap[$t]:-}" ]] || die "未知协议: $t"
            protocols+=("${pmap[$t]}")
        done
    fi
    echo "${protocols[@]}"
}

build_routes() {
    local net_mode="$1" path_prefix="$2"
    shift 2
    local protocols=("$@")
    local routes_json='[]'

    if [[ "$net_mode" == "nat" ]]; then
        echo >&2; info "NAT 模式: 逐个配置端口映射" >&2; echo >&2
        for proto in "${protocols[@]}"; do
            local int_port ext_port
            read -rp "${proto} 内部监听端口: " int_port
            [[ "$int_port" =~ ^[0-9]+$ ]] || die "无效端口: $int_port"
            read -rp "${proto} 外部映射端口: " ext_port
            [[ "$ext_port" =~ ^[0-9]+$ ]] || die "无效端口: $ext_port"
            local path="${path_prefix}-${PROTO_SUFFIX[$proto]}"
            routes_json=$(echo "$routes_json" | jq \
                --arg p "$proto" --argjson lp "$((int_port))" --argjson cp "$((ext_port))" --arg pa "$path" \
                '. + [{protocol:$p, listen_port:$lp, ext_port:$cp, path:$pa}]')
        done
    else
        read -rp "自定义端口?(逗号分隔，留空=随机): " custom_ports_raw
        local existing_ports; existing_ports=$(get_listening_ports)
        local custom_ports=()
        if [[ -n "$custom_ports_raw" ]]; then
            IFS=',' read -ra custom_ports <<< "$custom_ports_raw"
            [[ ${#custom_ports[@]} -eq ${#protocols[@]} ]] || die "端口数量与协议数不一致"
        fi
        local pi=0
        for proto in "${protocols[@]}"; do
            local port
            if [[ ${#custom_ports[@]} -gt 0 ]]; then
                port="${custom_ports[$pi]// /}"
                [[ "$port" =~ ^[0-9]+$ ]] || die "无效端口: $port"
            else
                port=$(rand_port "$existing_ports")
            fi
            existing_ports="$existing_ports $port"
            local path="${path_prefix}-${PROTO_SUFFIX[$proto]}"
            routes_json=$(echo "$routes_json" | jq \
                --arg p "$proto" --argjson lp "$((port))" --arg pa "$path" \
                '. + [{protocol:$p, listen_port:$lp, ext_port:$lp, path:$pa}]')
            pi=$((pi + 1))
        done
    fi
    echo "$routes_json"
}

# ── 1. 安装 ──────────────────────────────────────────
do_install() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] && die "检测到上次配置($(echo "$state" | jq -r '.domain // "?"'))，请先卸载"

    install_sb

    local net_mode; net_mode=$(prompt_net_mode "$(detect_nat)")
    ok "网络模式: $(net_mode_label "$net_mode")"

    prompt_cf

    local domain zone_id
    while true; do
        read -rp "绑定域名 (如 node.yourdomain.com): " domain || die "输入中断"
        [[ -z "$domain" ]] && { warn "域名不能为空"; continue; }
        if zone_id=$(cf_find_zone "$domain"); then
            info "匹配到 Zone: $zone_id"; break
        fi
        warn "无法匹配 Zone: $domain"
    done

    local protocols_str; protocols_str=$(prompt_protocols)
    read -ra protocols <<< "$protocols_str"

    local uuid
    read -rp "UUID/密码 (留空=自动生成，trojan 也用这个当密码): " custom_uuid
    if [[ -n "$custom_uuid" ]]; then
        [[ "$custom_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
        uuid="${custom_uuid,,}"
    else
        uuid=$(gen_uuid)
    fi

    local short_id="${uuid:0:8}"
    local path_prefix
    read -rp "WS 路径前缀 (留空=/${short_id}): " pfx
    [[ -z "$pfx" ]] && pfx="/${short_id}"
    [[ "$pfx" == /* ]] || pfx="/${pfx}"

    local routes_json; routes_json=$(build_routes "$net_mode" "$pfx" "${protocols[@]}")

    # 预览
    echo
    echo "====== 配置预览 ======"
    echo "  域名:  $domain"
    echo "  UUID:  $uuid (vless/vmess用, trojan当密码)"
    echo "  模式:  $net_mode"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol|ascii_upcase)  监听:\(.listen_port)  外部:\(.ext_port)  路径:\(.path)"'
    echo "======================="
    echo
    read -rp "确认部署? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    # 部署
    local config; config=$(gen_sb_config "$uuid" "$routes_json")
    write_sb_config "$config"
    [[ "$INIT_SYSTEM" == "openrc" && ! -f "$SB_OPENRC_SCRIPT" ]] && write_openrc_script && ok "OpenRC 脚本已创建"
    restart_sb

    local public_ip dns_before ssl_before origin_before dns_record_id security_backup
    public_ip=$(get_public_ip)
    dns_before=$(cf_get_dns "$zone_id" "$domain" || echo "null")
    [[ "$dns_before" == "" ]] && dns_before="null"
    ssl_before=$(cf_get_ssl "$zone_id")
    origin_before=$(cf_get_origin_rules "$zone_id")

    dns_record_id=$(cf_upsert_dns "$zone_id" "$domain" "$public_ip")
    ok "DNS: $domain -> $public_ip (代理)"
    cf_set_ssl "$zone_id" "flexible"
    ok "SSL: flexible"
    apply_origin_rules "$zone_id" "$domain" "$routes_json"
    ok "Origin Rules: $(echo "$routes_json" | jq 'length') 条"
    security_backup=$(cf_relax_security "$zone_id")

    local links_json; links_json=$(gen_all_links "$uuid" "$domain" "$routes_json")
    save_links_snapshot "$domain" "$uuid" "$links_json"

    [[ -n "$origin_before" ]] || origin_before="[]"
    [[ -n "$security_backup" ]] || security_backup="null"
    local dns_existed="false"; [[ "$dns_before" != "null" ]] && dns_existed="true"

    save_state "$(jq -n \
        --arg d "$domain" --arg z "$zone_id" --arg u "$uuid" --arg mode "$net_mode" \
        --argjson routes "$routes_json" \
        --arg drid "$dns_record_id" --argjson dex "$dns_existed" --argjson drec "$dns_before" \
        --arg ssl "$ssl_before" --argjson orbk "$origin_before" --argjson secbk "$security_backup" \
        --argjson links "$links_json" \
        '{domain:$d, zone_id:$z, uuid:$u, net_mode:$mode, routes:$routes,
          managed_dns_record_id:$drid, dns_backup:{existed:$dex, record:$drec},
          ssl_backup:$ssl, origin_rules_backup:$orbk, security_backup:$secbk, links:$links}')"

    echo; ok "部署完成！"; echo
    print_links "$links_json"
    echo; echo "  链接已保存到: $LAST_LINKS_PATH"
}

# ── 2. 卸载 ──────────────────────────────────────────
do_uninstall() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到配置"
    local domain; domain=$(echo "$state" | jq -r '.domain')
    echo "卸载: $domain"

    svc_stop; rm -f "$SB_CONFIG_PATH"
    ok "sing-box 已停止"

    if load_cf_account; then
        local zone_id; zone_id=$(echo "$state" | jq -r '.zone_id // ""')
        if [[ -n "$zone_id" ]]; then
            cf_put_origin_rules "$zone_id" "$(echo "$state" | jq '.origin_rules_backup // []')"
            ok "Origin Rules 已恢复"
            local ssl_bk; ssl_bk=$(echo "$state" | jq -r '.ssl_backup // ""')
            [[ -n "$ssl_bk" ]] && cf_set_ssl "$zone_id" "$ssl_bk" && ok "SSL 已恢复"
            local dns_existed record_id
            dns_existed=$(echo "$state" | jq -r '.dns_backup.existed')
            record_id=$(echo "$state" | jq -r '.managed_dns_record_id // ""')
            if [[ "$dns_existed" == "true" ]]; then
                local rp; rp=$(echo "$state" | jq '.dns_backup.record | {type:(.type//"A"),name:(.name//""),content:(.content//""),proxied:(.proxied//false),ttl:(.ttl//1)}')
                cf_call PUT "/zones/${zone_id}/dns_records/${record_id}" "$rp" >/dev/null
                ok "DNS 已恢复"
            elif [[ -n "$record_id" ]]; then
                cf_call_raw DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null 2>&1 || true
                ok "DNS 已删除"
            fi
            cf_restore_security "$zone_id" "$(echo "$state" | jq '.security_backup // null')"
        fi
    else
        warn "无 CF 凭据，跳过恢复"
    fi

    remove_state
    rm -f "$LAST_LINKS_PATH" "$CF_ACCOUNT_PATH"
    ok "已清理状态和凭据"
    ok "卸载完成"
}

# ── 3. 查看订阅 ──────────────────────────────────────
do_show() {
    if [[ -f "$LAST_LINKS_PATH" ]]; then cat "$LAST_LINKS_PATH"; return; fi
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "无历史配置"
    echo "域名: $(echo "$state" | jq -r '.domain')"
    echo "UUID: $(echo "$state" | jq -r '.uuid')"
    echo
    print_links "$(echo "$state" | jq '.links')"
}

# ── 4. 修改配置 ──────────────────────────────────────
do_modify() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain uuid routes_json net_mode zone_id
    domain=$(echo "$state" | jq -r '.domain')
    uuid=$(echo "$state" | jq -r '.uuid')
    routes_json=$(echo "$state" | jq '.routes')
    net_mode=$(echo "$state" | jq -r '.net_mode')
    zone_id=$(echo "$state" | jq -r '.zone_id')

    echo
    echo "当前配置 ($net_mode):"
    echo "  域名: $domain  UUID: $uuid"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol|ascii_upcase)  监听:\(.listen_port)  外部:\(.ext_port)  路径:\(.path)"'
    echo
    echo "  1. 修改 UUID/密码"
    echo "  2. 修改端口"
    echo "  3. 修改 WS 路径前缀"
    echo "  4. 全部修改"
    echo "  0. 返回"
    echo
    read -rp "请选择 [0-4]: " mc
    [[ "$mc" =~ ^[0-4]$ ]] || die "无效选项"
    [[ "$mc" == "0" ]] && return

    local new_uuid="$uuid" new_routes="$routes_json" changed=false

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
        local pc; pc=$(echo "$new_routes" | jq 'length')
        if [[ "$net_mode" == "nat" ]]; then
            echo "当前映射: $(echo "$new_routes" | jq -r '[.[] | "\(.listen_port):\(.ext_port)"] | join(",")')"
            read -rp "新映射(内部:外部，共${pc}组，逗号分隔，留空=不改): " mr
            if [[ -n "$mr" ]]; then
                IFS=',' read -ra maps <<< "$mr"
                [[ ${#maps[@]} -eq $pc ]] || die "数量不匹配"
                local idx=0
                for m in "${maps[@]}"; do
                    m="${m// /}"; local lp="${m%%:*}" cp="${m##*:}"
                    [[ "$lp" =~ ^[0-9]+$ && "$cp" =~ ^[0-9]+$ ]] || die "无效: $m"
                    new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson l "$((lp))" --argjson c "$((cp))" '.[$i].listen_port=$l|.[$i].ext_port=$c')
                    idx=$((idx+1))
                done
                changed=true; ok "端口已更新"
            fi
        else
            echo "当前端口: $(echo "$new_routes" | jq -r '[.[].listen_port|tostring] | join(",")')"
            read -rp "新端口(逗号分隔，共${pc}个，留空=不改): " pr
            if [[ -n "$pr" ]]; then
                IFS=',' read -ra nps <<< "$pr"
                [[ ${#nps[@]} -eq $pc ]] || die "数量不匹配"
                local idx=0
                for np in "${nps[@]}"; do
                    np="${np// /}"; [[ "$np" =~ ^[0-9]+$ ]] || die "无效端口"
                    new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((np))" '.[$i].listen_port=$p|.[$i].ext_port=$p')
                    idx=$((idx+1))
                done
                changed=true; ok "端口已更新"
            fi
        fi
    fi

    if [[ "$mc" == "3" || "$mc" == "4" ]]; then
        echo "当前路径: $(echo "$new_routes" | jq -r '[.[].path] | join(", ")')"
        read -rp "新路径前缀 (留空=不改): " np
        if [[ -n "$np" ]]; then
            [[ "$np" == /* ]] || np="/$np"
            new_routes=$(echo "$new_routes" | jq --arg pfx "$np" '[.[]|.path=($pfx+"-"+(if .protocol=="vless" then "vl" elif .protocol=="trojan" then "tr" else "vm" end))]')
            changed=true; ok "路径已更新"
        fi
    fi

    [[ "$changed" == "true" ]] || { echo "无修改"; return; }

    write_sb_config "$(gen_sb_config "$new_uuid" "$new_routes")"
    restart_sb
    load_cf_account || die "未找到 CF 凭据"
    apply_origin_rules "$zone_id" "$domain" "$new_routes"
    ok "Origin Rules 已更新"

    local public_ip current_ip
    public_ip=$(get_public_ip)
    current_ip=$(cf_get_dns "$zone_id" "$domain" | jq -r '.content // ""')
    [[ "$current_ip" != "$public_ip" ]] && cf_upsert_dns "$zone_id" "$domain" "$public_ip" >/dev/null && ok "DNS IP 已更新"

    local links_json; links_json=$(gen_all_links "$new_uuid" "$domain" "$new_routes")
    save_links_snapshot "$domain" "$new_uuid" "$links_json"
    save_state "$(echo "$state" | jq --arg u "$new_uuid" --argjson r "$new_routes" --argjson l "$links_json" '.uuid=$u|.routes=$r|.links=$l')"

    echo; ok "配置已更新"; echo
    print_links "$links_json"
}

# ── 5. 查看当前配置 ──────────────────────────────────
do_show_config() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    echo
    echo "  域名: $(echo "$state" | jq -r '.domain')"
    echo "  UUID: $(echo "$state" | jq -r '.uuid')"
    echo "  模式: $(net_mode_label "$(echo "$state" | jq -r '.net_mode')")"
    echo "  入站:"
    echo "$state" | jq -r '.routes[] | "    \(.protocol|ascii_upcase)  监听:\(.listen_port)  外部:\(.ext_port)  路径:\(.path)"'
    echo -n "  服务: "; svc_is_active && echo "运行中" || echo "未运行"
    echo "  订阅:"
    print_links "$(echo "$state" | jq '.links')"
    echo
}

# ── 6. 更新外部端口 (NAT) ────────────────────────────
do_update_ext_port() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    local net_mode; net_mode=$(echo "$state" | jq -r '.net_mode')
    [[ "$net_mode" == "nat" ]] || die "直连模式请用 [4.修改配置]"

    local domain routes_json zone_id
    domain=$(echo "$state" | jq -r '.domain')
    routes_json=$(echo "$state" | jq '.routes')
    zone_id=$(echo "$state" | jq -r '.zone_id')

    echo "当前端口映射:"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol|ascii_upcase)  监听:\(.listen_port) -> 外部:\(.ext_port)"'
    echo
    local pc; pc=$(echo "$routes_json" | jq 'length')
    info "只更新外部端口(CF Origin Rules)，xray 监听端口不变"
    echo
    local new_routes="$routes_json" idx=0
    local rows=() row
    mapfile -t rows < <(echo "$routes_json" | jq -r '.[] | [.protocol, (.ext_port|tostring)] | @tsv')
    for row in "${rows[@]}"; do
        local proto="${row%%$'\t'*}" old_cp="${row##*$'\t'}" ne
        read -rp "${proto} 新外部端口(当前=${old_cp}): " ne
        [[ -n "$ne" ]] || die "不能为空"
        [[ "$ne" =~ ^[0-9]+$ ]] || die "无效端口"
        new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((ne))" '.[$i].ext_port=$p')
        idx=$((idx+1))
    done
    echo
    echo "更新预览:"
    echo "$new_routes" | jq -r '.[] | "  \(.protocol|ascii_upcase)  监听:\(.listen_port) -> 外部:\(.ext_port)"'
    read -rp "确认? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    load_cf_account || die "未找到 CF 凭据"
    apply_origin_rules "$zone_id" "$domain" "$new_routes"
    ok "Origin Rules 已更新"

    local public_ip; public_ip=$(get_public_ip)
    local current_ip; current_ip=$(cf_get_dns "$zone_id" "$domain" | jq -r '.content // ""')
    [[ "$current_ip" != "$public_ip" ]] && cf_upsert_dns "$zone_id" "$domain" "$public_ip" >/dev/null && ok "DNS 已更新"

    local uid; uid=$(echo "$state" | jq -r '.uuid')
    local links_json; links_json=$(gen_all_links "$uid" "$domain" "$new_routes")
    save_links_snapshot "$domain" "$uid" "$links_json"
    save_state "$(echo "$state" | jq --argjson r "$new_routes" --argjson l "$links_json" '.routes=$r|.links=$l')"
    echo; ok "外部端口已更新"; echo
    print_links "$links_json"
}

# ── 7. 重启 ──────────────────────────────────────────
do_restart() {
    svc_is_active && echo "重启 sing-box..." || echo "启动 sing-box..."
    restart_sb
}

# ── 8. 切换网络模式 ──────────────────────────────────
do_switch_net_mode() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    local domain zone_id cur routes_json
    domain=$(echo "$state" | jq -r '.domain')
    zone_id=$(echo "$state" | jq -r '.zone_id')
    cur=$(echo "$state" | jq -r '.net_mode')
    routes_json=$(echo "$state" | jq '.routes')

    echo "当前模式: $(net_mode_label "$cur")"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol|ascii_upcase)  监听:\(.listen_port)  外部:\(.ext_port)"'
    echo
    local target
    if [[ "$cur" == "nat" ]]; then
        target="direct"
        echo "切成直连后，外部端口=监听端口"
    else
        target="nat"
        echo "切成 NAT 后，需为每个协议指定外部端口"
    fi
    read -rp "确认切换到 $(net_mode_label "$target")? (y/N): " c
    [[ "${c,,}" =~ ^(y|yes)$ ]] || die "已取消"

    local new_routes="$routes_json"
    if [[ "$target" == "direct" ]]; then
        new_routes=$(echo "$new_routes" | jq '[.[] | .ext_port = .listen_port]')
    else
        local idx=0 rows=() row
        mapfile -t rows < <(echo "$routes_json" | jq -r '.[] | [.protocol, (.listen_port|tostring)] | @tsv')
        for row in "${rows[@]}"; do
            local proto="${row%%$'\t'*}" lp="${row##*$'\t'}" ep
            read -rp "${proto} 对外端口(监听=${lp}, 回车=相同): " ep
            [[ -n "$ep" ]] || ep="$lp"
            [[ "$ep" =~ ^[0-9]+$ ]] || die "无效端口"
            new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((ep))" '.[$i].ext_port=$p')
            idx=$((idx+1))
        done
    fi
    echo
    echo "更新预览:"
    echo "$new_routes" | jq -r '.[] | "  \(.protocol|ascii_upcase)  监听:\(.listen_port)  外部:\(.ext_port)"'
    read -rp "确认? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    load_cf_account || die "未找到 CF 凭据"
    apply_origin_rules "$zone_id" "$domain" "$new_routes"
    ok "Origin Rules 已更新"

    local uid; uid=$(echo "$state" | jq -r '.uuid')
    local links_json; links_json=$(gen_all_links "$uid" "$domain" "$new_routes")
    save_links_snapshot "$domain" "$uid" "$links_json"
    save_state "$(echo "$state" | jq --arg m "$target" --argjson r "$new_routes" --argjson l "$links_json" '.net_mode=$m|.routes=$r|.links=$l')"
    echo; ok "已切换到 $(net_mode_label "$target")"; echo
    print_links "$links_json"
}

# ── 快捷入口 (一键安装后 sb 永久可用) ─────────────────
ensure_shortcut() {
    local target="/usr/local/bin/sb"
    cat > "$target" << 'SCEOF'
#!/bin/bash
SCRIPT="/etc/sb-cf-lite/sb-cf-lite.sh"
if [ -f "$SCRIPT" ]; then
    exec bash "$SCRIPT" "$@"
else
    echo "脚本未找到: $SCRIPT"
    echo "请重新运行: wget -qO /root/sb.sh <下载链接> && bash /root/sb.sh"
    exit 1
fi
SCEOF
    chmod +x "$target"
}

self_install() {
    mkdir -p "$STATE_DIR"
    local src="${BASH_SOURCE[0]}"
    if [ -f "$src" ]; then
        cp "$src" "$STATE_DIR/sb-cf-lite.sh" 2>/dev/null && ok "快捷入口已安装: sb" || warn "自复制失败"
    fi
}

# ── 主入口 ────────────────────────────────────────────
main() {
    [[ "$(id -u)" == "0" ]] || die "请使用 root 运行"
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
    echo "  sing-box CF Lite ($INIT_SYSTEM) — 多协议版"
    echo
    echo "  1. 安装节点"
    echo "  2. 卸载"
    echo "  3. 查看订阅"
    echo "  4. 修改配置 (UUID/端口/路径)"
    echo "  5. 查看当前配置"
    echo "  6. 更新外部端口 (NAT)"
    echo "  7. 重启 sing-box"
    echo "  8. 切换网络模式"
    [[ -n "$current_domain" ]] && echo "     (当前: $current_domain${net_mode:+ [$net_mode]})"
    echo
    read -rp "请选择 [1-8]: " choice
    case "$choice" in
        1) do_install ;; 2) do_uninstall ;; 3) do_show ;;
        4) do_modify ;; 5) do_show_config ;; 6) do_update_ext_port ;;
        7) do_restart ;; 8) do_switch_net_mode ;;
        *) die "无效选项: $choice" ;;
    esac
}

main "$@"
