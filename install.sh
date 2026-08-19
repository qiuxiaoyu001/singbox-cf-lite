#!/usr/bin/env bash
# ==========================================
# 项目: Sing-box CF Lite (专为NAT小鸡打造)
# 适配: Alpine (OpenRC) / Debian (Systemd) 自动双模兼容
# ==========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 0. 基础环境和 root 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

install_deps() {
    echo -e "${YELLOW}检查并安装基础依赖 (curl, jq, wget, openssl, tar)...${PLAIN}"
    if [ -x "$(command -v apt)" ]; then
        apt update && apt install -y curl jq wget openssl tar
    elif [ -x "$(command -v apk)" ]; then
        # 兼容 Alpine 系统的 bash/curl/jq 安装
        apk update && apk add bash curl jq wget openssl tar
    else
        echo -e "${RED}不支持的包管理器，请手动安装依赖后重试${PLAIN}"
        exit 1
    fi
}

get_inputs() {
    clear
    echo -e "${GREEN}=== Sing-box CF Lite 终极防误删全自动部署 ===${PLAIN}"
    echo -e "${YELLOW}提示: CF API 必须使用 Global API Key (全局API密钥)${PLAIN}"
    read -p "请输入 Cloudflare 账号邮箱: " CF_EMAIL
    read -p "请输入 Cloudflare Global API Key: " CF_KEY
    
    echo -e "\n${YELLOW}--- 域名设置 ---${PLAIN}"
    read -p "请输入你在 CF 后台看到的主域名 (例如 yourdomain.com 或 sub.eu.org): " MAIN_DOMAIN
    read -p "请输入你要作为节点的完整域名 (例如 999.yourdomain.com): " CF_DOMAIN
    
    echo -e "\n${YELLOW}--- 端口映射设置 ---${PLAIN}"
    read -p "请输入 内部监听端口 (sing-box 运行端口, 默认 8080): " INTERNAL_PORT
    INTERNAL_PORT=${INTERNAL_PORT:-8080}
    read -p "请输入 外部映射端口 (NAT 面板给你的公网端口, 例如 15638): " EXTERNAL_PORT
    if [ -z "$EXTERNAL_PORT" ]; then echo -e "${RED}外部端口不能为空！${PLAIN}"; exit 1; fi

    UUID=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    WS_PATH="/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)"
    
    echo -e "${GREEN}生成的 UUID: ${UUID}${PLAIN}"
    echo -e "${GREEN}生成的 WS 路径: ${WS_PATH}${PLAIN}"
}

install_singbox() {
    echo -e "${YELLOW}正在自动检测 CPU 架构并获取 Sing-box 最新版本...${PLAIN}"
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    VERSION_NUM=${LATEST_VERSION#v}
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) DL_ARCH="amd64" ;;
        aarch64|arm64) DL_ARCH="arm64" ;;
        armv7*) DL_ARCH="armv7" ;;
        *) echo -e "${RED}不支持的 CPU 架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    DL_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION_NUM}-linux-${DL_ARCH}.tar.gz"
    
    echo -e "${YELLOW}正在下载 Sing-box ${LATEST_VERSION} (${DL_ARCH})...${PLAIN}"
    wget -qO sing-box.tar.gz "$DL_URL"
    
    echo -e "${YELLOW}正在解压并安全安装核心文件...${PLAIN}"
    tar -xzf sing-box.tar.gz
    
    # 将二进制精准移动到安全位置
    mv sing-box-${VERSION_NUM}-linux-${DL_ARCH}/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    
    # 🔴 防误删核心：精准清理临时文件，绝对不使用通配符 rm -rf sing-box*
    rm -rf sing-box.tar.gz sing-box-${VERSION_NUM}-linux-${DL_ARCH}
    
    echo -e "${GREEN}Sing-box 安装成功并已做好安全防护！${PLAIN}"
}

generate_config() {
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "::",
      "listen_port": $INTERNAL_PORT,
      "users": [ { "name": "user1", "uuid": "$UUID" } ],
      "transport": { "type": "ws", "path": "$WS_PATH", "max_early_data": 0 }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
}

setup_service() {
    echo -e "${YELLOW}配置系统后台服务并注入 20MB 内存极限锁 (GOMEMLIMIT)...${PLAIN}"
    if [ -x "$(command -v systemctl)" ] && systemctl --version &>/dev/null; then
        # Systemd 环境 (Debian/Ubuntu)
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=1s
LimitNOFILE=infinity
Environment="GOGC=10"
Environment="GOMEMLIMIT=20MiB"
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box
    elif [ -x "$(command -v rc-update)" ]; then
        # OpenRC 环境 (Alpine Linux)
        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
command_env="GOGC=10 GOMEMLIMIT=20MiB"
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        rc-service sing-box restart
    else
        echo -e "${RED}未知的 init 系统，请手动后台运行 sing-box${PLAIN}"
    fi
}

setup_cf() {
    echo -e "${YELLOW}正在全自动配置 Cloudflare API (DNS, SSL, Origin Rules, WAF)...${PLAIN}"
    
    CF_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$MAIN_DOMAIN" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    
    ZONE_ID=$(echo "$CF_RESPONSE" | jq -r '.result[0].id')
    
    if [ "$ZONE_ID" == "null" ] || [ -z "$ZONE_ID" ]; then
        echo -e "${RED}获取 CF Zone ID 失败！请检查邮箱、Global API Key 或主域名拼写。${PLAIN}"
        exit 1
    fi

    # 1. 设置 SSL 为 Flexible
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
        -H "Content-Type: application/json" --data '{"value":"flexible"}' > /dev/null

    # 2. 自动配置 DNS (开启小云朵)
    PUBLIC_IP=$(curl -s ipv4.icanhazip.com)
    RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$CF_DOMAIN" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | jq -r '.result[0].id')

    if [ "$RECORD_ID" != "null" ]; then
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$CF_DOMAIN\",\"content\":\"$PUBLIC_IP\",\"proxied\":true}" > /dev/null
    else
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$CF_DOMAIN\",\"content\":\"$PUBLIC_IP\",\"proxied\":true}" > /dev/null
    fi

    # 3. 配置 Origin Rules (端口映射) - 安全追加模式
    ORIGIN_RULESET_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | jq -r '.result[] | select(.phase=="http_request_origin").id')
    ORIGIN_RULE_DATA="{\"description\":\"Singbox-NAT-Port-Override\",\"expression\":\"(http.host eq \\\"$CF_DOMAIN\\\")\",\"action\":\"route\",\"action_parameters\":{\"origin\":{\"port\":$EXTERNAL_PORT}}}"

    if [ -z "$ORIGIN_RULESET_ID" ]; then
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"name\":\"default\",\"phase\":\"http_request_origin\",\"rules\":[$ORIGIN_RULE_DATA]}" > /dev/null
    else
        HAS_ORIGIN=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$ORIGIN_RULESET_ID" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | grep "Singbox-NAT-Port-Override")
        if [ -z "$HAS_ORIGIN" ]; then
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$ORIGIN_RULESET_ID/rules" \
                -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
                --data "$ORIGIN_RULE_DATA" > /dev/null
        fi
    fi

    # 4. 配置 WAF 规则 (自动跳过 Bot Fight Mode 和 浏览器安全检查)
    WAF_RULESET_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | jq -r '.result[] | select(.phase=="http_request_firewall_custom").id')
    
    SKIP_RULE_DATA="{\"description\":\"Bypass-Security-For-Singbox\",\"expression\":\"(http.host eq \\\"$CF_DOMAIN\\\")\",\"action\":\"skip\",\"action_parameters\":{\"ruleset\":\"current\",\"products\":[\"bic\",\"security_level\",\"bot_management\",\"waf\"]}}"

    if [ -z "$WAF_RULESET_ID" ]; then
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"name\":\"default\",\"phase\":\"http_request_firewall_custom\",\"rules\":[$SKIP_RULE_DATA]}" > /dev/null
    else
        HAS_WAF=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$WAF_RULESET_ID" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | grep "Bypass-Security-For-Singbox")
        if [ -z "$HAS_WAF" ]; then
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$WAF_RULESET_ID/rules" \
                -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
                --data "$SKIP_RULE_DATA" > /dev/null
        fi
    fi

    echo -e "${GREEN}Cloudflare 全套规则配置完成！(WAF/防Bot已自动放行)${PLAIN}"
}

output_link() {
    VLESS_LINK="vless://${UUID}@${CF_DOMAIN}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&type=ws&host=${CF_DOMAIN}&path=$(echo $WS_PATH | jq -sRr @uri)#Singbox-CFLite-64M"
    
    echo -e "\n${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}部署成功！64MB 极限优化版 Sing-box 已在后台稳定运行。${PLAIN}"
    echo -e "${YELLOW}客户端导入链接 (复制以下内容):${PLAIN}\n"
    echo -e "${VLESS_LINK}\n"
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}所有配置（DNS, 端口映射, WAF放行）已全部自动化搞定！${PLAIN}"
}

# 执行完整流程
install_deps
get_inputs
install_singbox
generate_config
setup_service
setup_cf
output_link
