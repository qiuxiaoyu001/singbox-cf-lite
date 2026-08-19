#!/usr/bin/env bash
# ==========================================
# 项目: Sing-box CF Lite (专为 NAT 小鸡打造)
# 适配: Alpine (OpenRC) / Debian (Systemd) 自动双模兼容
# ==========================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# ========== 可调参数 ==========
MEM_LIMIT="48MiB"          # 64M 小鸡建议 40~48M，留 16~24M 给系统
GOGC_VAL="20"              # GC 触发比例，越大越省 CPU、越占内存
RESTART_SEC="3"            # 服务崩溃后重启间隔(秒)
# ==============================

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

install_deps() {
    echo -e "${YELLOW}检查并安装基础依赖...${PLAIN}"
    if [ -x "$(command -v apt)" ]; then
        apt update -qq && apt install -y -qq curl jq wget openssl tar
    elif [ -x "$(command -v apk)" ]; then
        apk update -q && apk add -q bash curl jq wget openssl tar
    else
        echo -e "${RED}不支持的包管理器${PLAIN}"; exit 1
    fi
}

get_inputs() {
    clear
    echo -e "${GREEN}=== Sing-box CF Lite 全自动部署 (修复版) ===${PLAIN}"
    echo -e "${YELLOW}提示: CF API 必须使用 Global API Key (全局API密钥)${PLAIN}"
    read -p "请输入 Cloudflare 账号邮箱: " CF_EMAIL
    read -p "请输入 Cloudflare Global API Key: " CF_KEY

    echo -e "\n${YELLOW}--- 域名设置 ---${PLAIN}"
    read -p "请输入主域名 (例如 yourdomain.com): " MAIN_DOMAIN
    read -p "请输入节点完整域名 (例如 999.yourdomain.com): " CF_DOMAIN

    echo -e "\n${YELLOW}--- 端口映射设置 ---${PLAIN}"
    read -p "内部监听端口 (默认 8080): " INTERNAL_PORT
    INTERNAL_PORT=${INTERNAL_PORT:-8080}
    read -p "外部映射端口 (NAT 面板给的公网端口): " EXTERNAL_PORT
    [ -z "$EXTERNAL_PORT" ] && echo -e "${RED}外部端口不能为空！${PLAIN}" && exit 1

    UUID=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    WS_PATH="/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)"

    echo -e "${GREEN}UUID: ${UUID}${PLAIN}"
    echo -e "${GREEN}WS 路径: ${WS_PATH}${PLAIN}"
}

install_singbox() {
    echo -e "${YELLOW}检测 CPU 架构并获取最新版本...${PLAIN}"
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    [ "$LATEST_VERSION" = "null" ] || [ -z "$LATEST_VERSION" ] && {
        echo -e "${RED}获取版本失败，使用固定版本 v1.8.11${PLAIN}"
        LATEST_VERSION="v1.8.11"
    }
    VERSION_NUM=${LATEST_VERSION#v}

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) DL_ARCH="amd64" ;;
        aarch64|arm64) DL_ARCH="arm64" ;;
        armv7*) DL_ARCH="armv7" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    DL_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION_NUM}-linux-${DL_ARCH}.tar.gz"
    echo -e "${YELLOW}下载 Sing-box ${LATEST_VERSION} (${DL_ARCH})...${PLAIN}"
    wget -qO sing-box.tar.gz "$DL_URL" || { echo -e "${RED}下载失败！${PLAIN}"; exit 1; }

    tar -xzf sing-box.tar.gz || { echo -e "${RED}解压失败！${PLAIN}"; exit 1; }
    mkdir -p /usr/local/bin

    # 精准移动，不使用通配符
    EXTRACTED_DIR="sing-box-${VERSION_NUM}-linux-${DL_ARCH}"
    if [ -f "$EXTRACTED_DIR/sing-box" ]; then
        mv "$EXTRACTED_DIR/sing-box" /usr/local/bin/
    else
        echo -e "${RED}解压后未找到 sing-box 二进制，实际目录内容:${PLAIN}"
        ls -la
        exit 1
    fi
    chmod +x /usr/local/bin/sing-box

    # 精准清理临时文件
    rm -rf sing-box.tar.gz "$EXTRACTED_DIR"

    # 验证安装
    if [ ! -f "/usr/local/bin/sing-box" ]; then
        echo -e "${RED}错误：Sing-box 核心安装失败！${PLAIN}"; exit 1
    fi
    echo -e "${GREEN}Sing-box 安装成功: $(/usr/local/bin/sing-box version | head -1)${PLAIN}"
}

generate_config() {
    mkdir -p /etc/sing-box /var/log
    cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true,
    "output": "/var/log/sing-box.log"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "::",
      "listen_port": $INTERNAL_PORT,
      "users": [ { "name": "user1", "uuid": "$UUID" } ],
      "transport": { "type": "ws", "path": "$WS_PATH" }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

    # 配置校验 — 关键！防止配置错误导致启动失败
    echo -e "${YELLOW}校验配置文件...${PLAIN}"
    if ! /usr/local/bin/sing-box check -c /etc/sing-box/config.json; then
        echo -e "${RED}配置文件校验失败！请检查上面的错误信息${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}配置校验通过${PLAIN}"
}

setup_service() {
    echo -e "${YELLOW}配置后台服务 (内存限制 ${MEM_LIMIT})...${PLAIN}"

    if [ -x "$(command -v systemctl)" ] && systemctl --version &>/dev/null; then
        # ===== Systemd (Debian/Ubuntu) =====
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=${RESTART_SEC}
LimitNOFILE=1048576
Environment="GOGC=${GOGC_VAL}"
Environment="GOMEMLIMIT=${MEM_LIMIT}"
StandardOutput=append:/var/log/sing-box.log
StandardError=append:/var/log/sing-box.log

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box
        sleep 2

        # 检查服务状态
        if ! systemctl is-active --quiet sing-box; then
            echo -e "${RED}服务启动失败！最近日志:${PLAIN}"
            journalctl -u sing-box --no-pager -n 20
            exit 1
        fi
        echo -e "${GREEN}Systemd 服务运行中 (PID $(systemctl show -p MainPID --value sing-box))${PLAIN}"

    elif [ -x "$(command -v rc-update)" ]; then
        # ===== OpenRC (Alpine) =====
        # 修复: 使用 start_pre 注入环境变量，兼容所有 Alpine 版本
        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
}

start_pre() {
    export GOGC="${GOGC_VAL}"
    export GOMEMLIMIT="${MEM_LIMIT}"
    checkpath -f -m 0644 /var/log/sing-box.log
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default 2>/dev/null

        # 先停掉可能残留的旧进程
        rc-service sing-box stop 2>/dev/null
        pkill -f "sing-box run" 2>/dev/null
        sleep 1

        rc-service sing-box start
        sleep 2

        # 检查服务状态
        if ! rc-service sing-box status 2>/dev/null | grep -q "started"; then
            echo -e "${RED}OpenRC 服务启动失败！日志:${PLAIN}"
            tail -20 /var/log/sing-box.log 2>/dev/null
            echo -e "${YELLOW}尝试前台启动排查...${PLAIN}"
            GOGC=${GOGC_VAL} GOMEMLIMIT=${MEM_LIMIT} /usr/local/bin/sing-box run -c /etc/sing-box/config.json &
            sleep 2
            if pgrep -f "sing-box run" > /dev/null; then
                echo -e "${GREEN}前台启动成功，已转为后台运行${PLAIN}"
            else
                echo -e "${RED}前台启动也失败，请检查配置${PLAIN}"
                exit 1
            fi
        else
            echo -e "${GREEN}OpenRC 服务运行中 (PID $(cat /run/sing-box.pid 2>/dev/null))${PLAIN}"
        fi
    else
        echo -e "${RED}未知 init 系统，请手动后台运行${PLAIN}"
        exit 1
    fi

    # ===== 通用: 端口监听检查 =====
    sleep 1
    if command -v ss &>/dev/null; then
        if ss -tlnp | grep -q ":$INTERNAL_PORT "; then
            echo -e "${GREEN}端口 $INTERNAL_PORT 正在监听 ✓${PLAIN}"
        else
            echo -e "${RED}端口 $INTERNAL_PORT 未监听！服务可能未正常启动${PLAIN}"
            echo -e "${YELLOW}当前监听端口:${PLAIN}"
            ss -tlnp 2>/dev/null | head -10
            exit 1
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":$INTERNAL_PORT "; then
            echo -e "${GREEN}端口 $INTERNAL_PORT 正在监听 ✓${PLAIN}"
        else
            echo -e "${RED}端口 $INTERNAL_PORT 未监听！${PLAIN}"
            exit 1
        fi
    fi
}

setup_cf() {
    echo -e "${YELLOW}配置 Cloudflare API...${PLAIN}"

    CF_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$MAIN_DOMAIN" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")

    ZONE_ID=$(echo "$CF_RESPONSE" | jq -r '.result[0].id')
    if [ "$ZONE_ID" = "null" ] || [ -z "$ZONE_ID" ]; then
        echo -e "${RED}获取 Zone ID 失败！检查邮箱/API Key/主域名${PLAIN}"
        echo "$CF_RESPONSE" | jq .
        exit 1
    fi
    echo -e "${GREEN}Zone ID: $ZONE_ID${PLAIN}"

    # 1. SSL Flexible
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
        -H "Content-Type: application/json" --data '{"value":"flexible"}' > /dev/null

    # 2. DNS 记录
    PUBLIC_IP=$(curl -s ipv4.icanhazip.com)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s ifconfig.me)
    echo -e "${GREEN}公网 IP: $PUBLIC_IP${PLAIN}"

    RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$CF_DOMAIN" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | jq -r '.result[0].id')

    if [ "$RECORD_ID" != "null" ] && [ -n "$RECORD_ID" ]; then
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$CF_DOMAIN\",\"content\":\"$PUBLIC_IP\",\"proxied\":true}" > /dev/null
    else
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$CF_DOMAIN\",\"content\":\"$PUBLIC_IP\",\"proxied\":true}" > /dev/null
    fi

    # 3. Origin Rules (端口映射)
    ORIGIN_RULESET_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | jq -r '.result[] | select(.phase=="http_request_origin").id')

    ORIGIN_RULE_DATA="{\"description\":\"Singbox-NAT-Port-Override\",\"expression\":\"(http.host eq \\\"$CF_DOMAIN\\\")\",\"action\":\"route\",\"action_parameters\":{\"origin\":{\"port\":$EXTERNAL_PORT}}}"

    if [ -z "$ORIGIN_RULESET_ID" ]; then
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"name\":\"default\",\"phase\":\"http_request_origin\",\"rules\":[$ORIGIN_RULE_DATA]}" > /dev/null
    else
        HAS_ORIGIN=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$ORIGIN_RULESET_ID" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | grep "Singbox-NAT-Port-Override")
        if [ -z "$HAS_ORIGIN" ]; then
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$ORIGIN_RULESET_ID/rules" \
                -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
                --data "$ORIGIN_RULE_DATA" > /dev/null
        fi
    fi

    # 4. WAF 放行
    WAF_RULESET_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | jq -r '.result[] | select(.phase=="http_request_firewall_custom").id')

    SKIP_RULE_DATA="{\"description\":\"Bypass-Security-For-Singbox\",\"expression\":\"(http.host eq \\\"$CF_DOMAIN\\\")\",\"action\":\"skip\",\"action_parameters\":{\"ruleset\":\"current\",\"products\":[\"bic\",\"security_level\",\"bot_management\",\"waf\"]}}"

    if [ -z "$WAF_RULESET_ID" ]; then
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"name\":\"default\",\"phase\":\"http_request_firewall_custom\",\"rules\":[$SKIP_RULE_DATA]}" > /dev/null
    else
        HAS_WAF=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$WAF_RULESET_ID" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | grep "Bypass-Security-For-Singbox")
        if [ -z "$HAS_WAF" ]; then
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$WAF_RULESET_ID/rules" \
                -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
                --data "$SKIP_RULE_DATA" > /dev/null
        fi
    fi

    echo -e "${GREEN}Cloudflare 配置完成 (DNS/SSL/Origin Rules/WAF)${PLAIN}"
}

output_link() {
    VLESS_LINK="vless://${UUID}@${CF_DOMAIN}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&type=ws&host=${CF_DOMAIN}&path=$(echo -n "$WS_PATH" | jq -sRr @uri)#Singbox-CFLite-64M"

    echo -e "\n${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}部署成功！${PLAIN}"
    echo -e "${YELLOW}进程状态:${PLAIN} $(pgrep -f 'sing-box run' > /dev/null && echo '运行中 ✓' || echo '未运行 ✗')"
    echo -e "${YELLOW}内存限制:${PLAIN} ${MEM_LIMIT}"
    echo -e "${YELLOW}日志文件:${PLAIN} /var/log/sing-box.log"
    echo -e "\n${YELLOW}客户端导入链接:${PLAIN}\n"
    echo -e "${VLESS_LINK}\n"
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${YELLOW}排查命令:${PLAIN}"
    echo -e "  查看进程: ps aux | grep sing-box"
    echo -e "  查看端口: ss -tlnp | grep $INTERNAL_PORT"
    echo -e "  查看日志: tail -f /var/log/sing-box.log"
    echo -e "  重启服务: $(command -v systemctl >/dev/null && echo 'systemctl restart sing-box' || echo 'rc-service sing-box restart')"
}

# 执行完整流程
install_deps
get_inputs
install_singbox
generate_config
setup_service
setup_cf
output_link
