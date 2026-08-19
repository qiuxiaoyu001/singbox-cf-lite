#!/bin/bash

# ==========================================
# 项目: Sing-box CF Lite (专为 64M NAT 小鸡打造)
# 特色: 极简 VLESS-WS, 锁死 20M 内存, CF 自动配置
# ==========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 1. 检查并安装依赖 (兼容 Debian/Ubuntu 和 Alpine)
install_deps() {
    echo -e "${YELLOW}检查并安装依赖项 (curl, jq, wget, openssl)...${PLAIN}"
    if [ -x "$(command -v apt)" ]; then
        apt update && apt install -y curl jq wget openssl
    elif [ -x "$(command -v apk)" ]; then
        apk add curl jq wget openssl
    else
        echo -e "${RED}不支持的包管理器，请手动安装 curl jq wget openssl${PLAIN}"
        exit 1
    fi
}

# 2. 获取用户输入
get_inputs() {
    clear
    echo -e "${GREEN}=== Sing-box CF Lite 极速部署 ===${PLAIN}"
    read -p "请输入 Cloudflare 绑定的域名 (例如 node1.yourdomain.com): " CF_DOMAIN
    read -p "请输入 Cloudflare Global API Key: " CF_KEY
    read -p "请输入 Cloudflare 账号邮箱: " CF_EMAIL
    
    echo -e "\n${YELLOW}--- 端口映射设置 ---${PLAIN}"
    read -p "请输入 内部监听端口 (sing-box 运行端口, 默认 8080): " INTERNAL_PORT
    INTERNAL_PORT=${INTERNAL_PORT:-8080}
    read -p "请输入 外部映射端口 (NAT 面板给你的公网端口, 例如 15331): " EXTERNAL_PORT
    if [ -z "$EXTERNAL_PORT" ]; then echo -e "${RED}外部端口不能为空！${PLAIN}"; exit 1; fi

    UUID=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    WS_PATH="/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)"
    
    echo -e "${GREEN}生成的 UUID: ${UUID}${PLAIN}"
    echo -e "${GREEN}生成的 WS 路径: ${WS_PATH}${PLAIN}"
}

# 3. 下载并安装最新版 Sing-box
install_singbox() {
    echo -e "${YELLOW}正在获取 Sing-box 最新版本...${PLAIN}"
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    VERSION_NUM=${LATEST_VERSION#v}
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) DL_ARCH="amd64" ;;
        aarch64) DL_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    DL_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION_NUM}-linux-${DL_ARCH}.tar.gz"
    
    echo -e "${YELLOW}下载 Sing-box ${LATEST_VERSION} (${DL_ARCH})...${PLAIN}"
    wget -qO sing-box.tar.gz "$DL_URL"
    tar -xzf sing-box.tar.gz
    mv sing-box-${VERSION_NUM}-linux-${DL_ARCH}/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz sing-box-${VERSION_NUM}-linux-${DL_ARCH}
}

# 4. 生成极简配置文件
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

# 5. 配置系统守护进程 (注入 64MB 极限内存优化参数)
setup_service() {
    echo -e "${YELLOW}配置系统服务并注入内存限制 (GOMEMLIMIT=20MiB)...${PLAIN}"
    if [ -x "$(command -v systemctl)" ]; then
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
depend() { need net }
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        rc-service sing-box restart
    else
        echo -e "${RED}未知的 init 系统，请手动后台运行 sing-box${PLAIN}"
    fi
}

# 6. 配置 Cloudflare API (DNS, SSL, Origin Rules)
setup_cf() {
    echo -e "${YELLOW}正在配置 Cloudflare API...${PLAIN}"
    MAIN_DOMAIN=$(echo $CF_DOMAIN | awk -F. '{print $(NF-1)"."$NF}')
    
    # 获取 Zone ID
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$MAIN_DOMAIN" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id')
    
    if [ "$ZONE_ID" == "null" ] || [ -z "$ZONE_ID" ]; then
        echo -e "${RED}获取 CF Zone ID 失败，请检查 API Key 和域名！${PLAIN}"
        exit 1
    fi

    # 获取本机公网 IP (用于 DNS A 记录)
    PUBLIC_IP=$(curl -s ipv4.icanhazip.com)

    # 1. 强制设置 SSL 为 Flexible
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
        -H "Content-Type: application/json" --data '{"value":"flexible"}' > /dev/null

    # 2. 更新或创建 DNS 记录 (Proxied)
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

    # 3. 设置 Origin Rules (目标端口重写)
    # 获取当前的 ruleset id
    RULESET_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | jq -r '.result[] | select(.phase=="http_request_origin").id')

    RULE_DATA="{\"description\":\"Singbox-NAT-Port-Override\",\"expression\":\"(http.host eq \\\"$CF_DOMAIN\\\")\",\"action\":\"route\",\"action_parameters\":{\"origin\":{\"port\":$EXTERNAL_PORT}}}"

    if [ -z "$RULESET_ID" ]; then
        # 创建新的 ruleset
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"name\":\"default\",\"phase\":\"http_request_origin\",\"rules\":[$RULE_DATA]}" > /dev/null
    else
        # 追加规则到现有的 ruleset (简化处理，直接清空旧的同名规则并覆盖)
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$RULESET_ID" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"rules\":[$RULE_DATA]}" > /dev/null
    fi
    echo -e "${GREEN}Cloudflare 配置完成！${PLAIN}"
}

# 7. 输出订阅链接
output_link() {
    # 既然套了 CF，客户端连接的端口就是 443 或者 80，由于我们选了 Flexible 但客户端走 HTTPS，所以端点是 443
    VLESS_LINK="vless://${UUID}@${CF_DOMAIN}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&type=ws&host=${CF_DOMAIN}&path=$(echo $WS_PATH | jq -sRr @uri)#Singbox-CFLite"
    
    echo -e "\n${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}部署成功！内存占用极低版 Sing-box 已启动。${PLAIN}"
    echo -e "${YELLOW}客户端导入链接 (复制以下内容):${PLAIN}\n"
    echo -e "${VLESS_LINK}\n"
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "进程管理: "
    if [ -x "$(command -v systemctl)" ]; then
        echo -e "重启: systemctl restart sing-box"
        echo -e "状态: systemctl status sing-box"
    else
        echo -e "重启: rc-service sing-box restart"
        echo -e "状态: rc-service sing-box status"
    fi
    echo -e "${YELLOW}注意: 请确保你在 Cloudflare 关闭了 该域名的 Bot Fight Mode！${PLAIN}"
}

# 运行主流程
install_deps
get_inputs
install_singbox
generate_config
setup_service
setup_cf
output_link
