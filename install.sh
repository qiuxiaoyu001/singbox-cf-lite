#!/bin/bash

# ==========================================
# 项目: Sing-box CF Lite (专为 64M NAT 小鸡打造) - 修复版
# 特色: 极简 VLESS-WS, 锁死 20M 内存, CF 自动配置, 兼容 Alpine
# ==========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

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

get_inputs() {
    clear
    echo -e "${GREEN}=== Sing-box CF Lite 极速部署 ===${PLAIN}"
    
    echo -e "${YELLOW}注意: CF API 必须使用 Global API Key (全局API密钥)！${PLAIN}"
    read -p "请输入 Cloudflare 账号邮箱: " CF_EMAIL
    read -p "请输入 Cloudflare Global API Key: " CF_KEY
    
    echo -e "\n${YELLOW}--- 域名设置 ---${PLAIN}"
    read -p "请输入你在 CF 后台看到的主域名 (例如 yourdomain.com 或 sub.eu.org): " MAIN_DOMAIN
    read -p "请输入你要作为节点的完整域名 (例如 node1.yourdomain.com): " CF_DOMAIN
    
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
    echo -e "${YELLOW}配置系统服务并注入内存限制 (GOMEMLIMIT=20MiB)...${PLAIN}"
    if [ -x "$(command -v systemctl)" ]; then
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
        # 修复了 OpenRC 的语法错误
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
    echo -e "${YELLOW}正在配置 Cloudflare API...${PLAIN}"
    
    # 增加完整的 API 错误回显
    CF_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$MAIN_DOMAIN" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    
    ZONE_ID=$(echo "$CF_RESPONSE" | jq -r '.result[0].id')
    
    if [ "$ZONE_ID" == "null" ] || [ -z "$ZONE_ID" ]; then
        echo -e "${RED}获取 CF Zone ID 失败！${PLAIN}"
        echo -e "${YELLOW}Cloudflare 接口返回以下错误信息：${PLAIN}"
        echo "$CF_RESPONSE" | jq .
        echo -e "${RED}请检查：\n1. 邮箱和 Global API Key 是否正确填写（不能用 Token）。\n2. 主域名是否在 CF 后台存在。${PLAIN}"
        exit 1
    fi

    echo -e "${GREEN}成功获取 Zone ID: $ZONE_ID${PLAIN}"

    PUBLIC_IP=$(curl -s ipv4.icanhazip.com)

    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
        -H "Content-Type: application/json" --data '{"value":"flexible"}' > /dev/null

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

    RULESET_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" | jq -r '.result[] | select(.phase=="http_request_origin").id')

    RULE_DATA="{\"description\":\"Singbox-NAT-Port-Override\",\"expression\":\"(http.host eq \\\"$CF_DOMAIN\\\")\",\"action\":\"route\",\"action_parameters\":{\"origin\":{\"port\":$EXTERNAL_PORT}}}"

    if [ -z "$RULESET_ID" ]; then
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"name\":\"default\",\"phase\":\"http_request_origin\",\"rules\":[$RULE_DATA]}" > /dev/null
    else
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$RULESET_ID" \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" \
            --data "{\"rules\":[$RULE_DATA]}" > /dev/null
    fi
    echo -e "${GREEN}Cloudflare 配置完成！${PLAIN}"
}

output_link() {
    VLESS_LINK="vless://${UUID}@${CF_DOMAIN}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&type=ws&host=${CF_DOMAIN}&path=$(echo $WS_PATH | jq -sRr @uri)#Singbox-CFLite"
    
    echo -e "\n${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}部署成功！内存占用极低版 Sing-box 已启动。${PLAIN}"
    echo -e "${YELLOW}客户端导入链接 (复制以下内容):${PLAIN}\n"
    echo -e "${VLESS_LINK}\n"
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${YELLOW}注意: 请确保你在 Cloudflare 关闭了 该域名的 Bot Fight Mode！${PLAIN}"
}

install_deps
get_inputs
install_singbox
generate_config
setup_service
setup_cf
output_link
