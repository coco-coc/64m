#!/bin/bash
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

# 检测系统类型
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif grep -q "Ubuntu" /etc/os-release; then
        echo "ubuntu"
    elif grep -q "Debian" /etc/os-release; then
        echo "debian"
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

# 颜色输出函数
red() { echo -e "${RED}$1${NC}"; }
green() { echo -e "${GREEN}$1${NC}"; }
yellow() { echo -e "${YELLOW}$1${NC}"; }
blue() { echo -e "${BLUE}$1${NC}"; }

# 安装依赖
install_deps() {
    case "$OS_TYPE" in
        "alpine")
            apk update
            apk add curl wget unzip iptables nc start-stop-daemon openssl
            ;;
        "debian"|"ubuntu")
            apt update
            apt install -y curl wget unzip netcat-openbsd iptables iptables-persistent openssl
            ;;
        *)
            red "不支持的系统类型！"
            exit 1
            ;;
    esac
}

# 服务管理配置
setup_service() {
    case "$OS_TYPE" in
        "alpine")
            cat << EOF > /etc/init.d/xray
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="/root/Xray/xray"
command_args="-config /root/Xray/config.json"
pidfile="/run/xray.pid"
respawn_delay=5
rc_ulimit="-n 30000"
output_log="/var/log/xray.log"
error_log="/var/log/xray.error.log"

depend() {
    need net
    after firewall
}

start() {
    ebegin "Starting xray service"
    start-stop-daemon --start \\
        --exec \$command \\
        --background \\
        --make-pidfile \\
        --pidfile \$pidfile \\
        -- \\
        \$command_args
    eend \$?
}

stop() {
    ebegin "Stopping xray service"
    start-stop-daemon --stop \\
        --exec \$command \\
        --pidfile \$pidfile
    eend \$?
}
EOF
            chmod +x /etc/init.d/xray
            mkdir -p /var/log
            touch /var/log/xray.log
            rc-update add xray default
            service xray restart
            ;;
        "debian"|"ubuntu")
            cat << EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/root/Xray/xray -config /root/Xray/config.json
Restart=always
User=root
LimitNOFILE=30000
StandardOutput=file:/var/log/xray.log
StandardError=file:/var/log/xray.error.log

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable xray
            systemctl restart xray
            ;;
    esac
}

# 证书配置（增加证书验证）
setup_certificates() {
    read -p "请选择：1.已上传证书文件，输入证书路径；2.未上传证书，直接输入证书内容.(默认选择1)： " is_path
    [[ -z $is_path ]] && is_path=1
    if [[ $is_path == 1 ]]; then
        read -p "请输入.crt结尾的证书绝对路径：" cert
        until [[ -f "$cert" ]]; do
            red "找不到文件！请检查输入路径！"
            read -p "请输入.crt结尾的证书绝对路径：" cert
        done
        read -p "请输入.key结尾的证书绝对路径：" key
        until [[ -f "$key" ]]; do
            red "找不到文件！请检查输入路径！"
            read -p "请输入.key结尾的证书绝对路径：" key
        done
        CERT_PATH="$cert"
        KEY_PATH="$key"
    else
        mkdir -p /root/Xray
        chmod 700 /root/Xray

        # 输入证书内容（修复换行符处理）
        yellow "请输入证书内容（输入空行结束）："
        cert_txt=""
        while IFS= read -r line; do
            if [[ -z "$line" ]]; then
                break
            fi
            cert_txt+="$line\n"
        done

        echo -e "$cert_txt" | sed '/^$/d' > /root/Xray/domain.crt
        yellow "证书被保存在：/root/Xray/domain.crt"

        # 输入私钥内容
        yellow "请输入对应的key内容（输入空行结束）："
        key_txt=""
        while IFS= read -r line; do
            if [[ -z "$line" ]]; then
                break
            fi
            key_txt+="$line\n"
        done

        echo -e "$key_txt" | sed '/^$/d' > /root/Xray/domain.key
        yellow "证书被保存在：/root/Xray/domain.key"

        CERT_PATH="/root/Xray/domain.crt"
        KEY_PATH="/root/Xray/domain.key"
    fi

    # 验证证书匹配性
    cert_md5=$(openssl x509 -noout -modulus -in "$CERT_PATH" | openssl md5 | cut -d' ' -f2)
    key_md5=$(openssl rsa -noout -modulus -in "$KEY_PATH" | openssl md5 | cut -d' ' -f2)
    
    if [[ "$cert_md5" != "$key_md5" ]]; then
        red "证书与私钥不匹配！"
        exit 1
    fi
    green "√ 证书验证通过"
}

# 生成协议配置（修复客户端配置）
generate_config() {
    case "$PROTOCOL" in
        "vmess")
            CLIENT_CONFIG="\"id\": \"$UUID\", \"alterId\": 0, \"security\": \"auto\""
            ;;
        "trojan")
            CLIENT_CONFIG="\"password\": \"$PASSWORD\""
            ;;
    esac

    cat << EOF > /root/Xray/config.json
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray-access.log",
        "error": "/var/log/xray-error.log"
    },
    "inbounds": [{
        "port": $IN_PORT,
        "protocol": "$PROTOCOL",
        "settings": {
            "clients": [{ $CLIENT_CONFIG }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "wsSettings": {
                "path": "$WS_PATH",
                "headers": { "Host": "$DOMAIN" }
            },
            "tlsSettings": {
                "certificates": [{
                    "certificateFile": "$CERT_PATH",
                    "keyFile": "$KEY_PATH"
                }],
                "alpn": ["http/1.1"],
                "serverName": "$DOMAIN"
            }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
}

# 生成客户端链接（增加sni参数）
generate_links() {
    blue "\n=============== 客户端配置链接 ================"
    case "$PROTOCOL" in
        "vmess")
            VMESS_JSON=$(cat <<EOF
{
    "v": "2",
    "ps": "Xray_VMess",
    "add": "$DOMAIN",
    "port": "$IN_PORT",
    "id": "$UUID",
    "scy": "auto",
    "net": "ws",
    "type": "none",
    "host": "$DOMAIN",
    "path": "$WS_PATH",
    "tls": "tls",
    "sni": "$DOMAIN",
    "alpn": ""
}
EOF
            )
            VMESS_LINK="vmess://$(echo "$VMESS_JSON" | base64 -w 0)"
            green "VMess 链接：\n$VMESS_LINK"
            ;;
        "trojan")
            TROJAN_LINK="trojan://${PASSWORD}@${DOMAIN}:${IN_PORT}?security=tls&sni=${DOMAIN}&alpn=&type=ws&host=${DOMAIN}&path=${WS_PATH}#Xray_Trojan"
            green "Trojan 链接：\n$TROJAN_LINK"
            ;;
    esac
    blue "================================================\n"
}

# 主流程
main() {
    # 清理旧日志
    rm -f /var/log/xray*.log

    yellow "检测系统类型：$OS_TYPE"
    yellow "开始安装依赖..."
    install_deps

    # 选择协议
    yellow "请选择协议："
    select protocol in "vmess" "trojan"; do
        PROTOCOL=$protocol
        break
    done

    # 输入域名和路径
    read -p "请输入域名（已解析到本机IP）：" DOMAIN
    read -p "请输入WebSocket路径（默认/）：" WS_PATH
    [[ -z "$WS_PATH" ]] && WS_PATH="/"

    # 配置证书
    setup_certificates

    # 生成认证信息
    if [[ "$PROTOCOL" == "trojan" ]]; then
        read -p "请输入Trojan密码（默认随机生成）：" PASSWORD
        [[ -z "$PASSWORD" ]] && PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        green "Trojan 密码已生成：$PASSWORD"
    else
        UUID=$(cat /proc/sys/kernel/random/uuid)
        green "VMess UUID 已生成：$UUID"
    fi

    # 端口配置（强制使用443）
    read -p "请输入监听端口（默认443）：" IN_PORT
    [[ -z "$IN_PORT" ]] && IN_PORT=443
    if [[ "$IN_PORT" != "443" ]]; then
        yellow "建议使用443端口以提高兼容性"
    fi

    # 下载Xray（更新至最新版）
    if [[ ! -f "/root/Xray/xray" ]]; then
        LATEST_TAG="v1.8.12"
        yellow "正在下载 Xray $LATEST_TAG ..."
        if ! wget -O Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/download/$LATEST_TAG/Xray-linux-64.zip"; then
            red "下载 Xray 失败！请检查网络或版本号！"
            exit 1
        fi
        mkdir -p /root/Xray
        unzip -o -d /root/Xray Xray-linux-64.zip
        chmod +x /root/Xray/xray
        rm -f Xray-linux-64.zip
    fi

    # 生成配置文件
    generate_config

    # 配置服务
    setup_service

    # 保存iptables规则
    if [[ "$OS_TYPE" != "alpine" ]]; then
        iptables-save > /etc/iptables/rules.v4
    else
        iptables-save > /etc/iptables/rules
    fi

    # 生成客户端链接
    generate_links

    # 显示日志路径
    yellow "访问日志：/var/log/xray-access.log"
    yellow "错误日志：/var/log/xray-error.log"
    green "Xray 服务配置完成！"
}

# 执行主流程
main
