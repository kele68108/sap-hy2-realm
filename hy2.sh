#!/usr/bin/env bash
# ==========================================
# 卸载逻辑：运行 bash hy2.sh uninstall 触发
# ==========================================
if [ "$1" == "uninstall" ]; then
    echo "[SYSTEM] 开始执行 hy2 卸载程序..."
    fuser -k -9 8343/udp >/dev/null 2>&1
    lsof -ti:8343 | xargs kill -9 >/dev/null 2>&1
    rm -rf ./tmp_hy2 ~/hy2-server.log >/dev/null 2>&1
    sed -i '/hy2.sh/d' ~/.bashrc
    sed -i '/Auto-run Proxy Script/d' ~/.bashrc
    echo "[SYSTEM] 卸载完成！hy2 已彻底从系统中清除。"
    exit 0
fi

# ==========================================
# 用户配置区 (极限隐蔽模式 + 指纹校验)
# ==========================================
FILE_PATH="./tmp_hy2"
UUID="6948adff-5e1e-4f52-9c9c-11b707390b8b"
PORT=8343
REALM_ID="QwenPaw-sg-hy2-kele666"

# 0. 防呆设计：清理旧进程
fuser -k -9 $PORT/udp >/dev/null 2>&1
lsof -ti:$PORT | xargs kill -9 >/dev/null 2>&1

# 1. 环境准备
if [ ! -d "$FILE_PATH" ]; then
    mkdir -p "$FILE_PATH/cert"
else
    rm -rf "$FILE_PATH"/* 2>/dev/null
    mkdir -p "$FILE_PATH/cert"
fi

CORE_NAME=$(tr -dc a-z </dev/urandom | head -c 6)
CORE_PATH="$FILE_PATH/$CORE_NAME"
CONFIG_PATH="$FILE_PATH/config.json"

# 2. 签发临时 TLS 证书并提取 SHA256 指纹
openssl ecparam -genkey -name prime256v1 -out "$FILE_PATH/cert/private.key" 2>/dev/null
openssl req -new -x509 -days 36500 -key "$FILE_PATH/cert/private.key" -out "$FILE_PATH/cert/cert.pem" -subj "/CN=cloudflare.com" 2>/dev/null

# 核心步骤：提取证书的 SHA256 哈希值 (适配 Xray 新规)
CERT_HASH=$(openssl x509 -in "$FILE_PATH/cert/cert.pem" -outform DER | openssl dgst -sha256 | awk '{print $2}')

# 3. 生成服务端 JSON 配置
cat <<EOF > "$CONFIG_PATH"
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-realm-in",
      "listen": "0.0.0.0",
      "listen_port": $PORT,
      "users": [ { "password": "$UUID" } ],
      "realm": {
        "server_url": "https://realm.hy2.io",
        "token": "public",
        "realm_id": "$REALM_ID",
        "stun_servers": [ "turn.cloudflare.com:3478" ]
      },
      "tls": {
        "enabled": true,
        "certificate_path": "$FILE_PATH/cert/cert.pem",
        "key_path": "$FILE_PATH/cert/private.key",
        "alpn": [ "h3" ]
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "domain_suffix": ["hy2.io", "cloudflare.com", "nextcloud.com", "sip.us"], "outbound": "direct" },
      { "inbound": ["hy2-realm-in"], "outbound": "direct" }
    ],
    "final": "direct"
  }
}
EOF

# 4. 下载核心组件 (升级至 1.14.0-alpha.35 保持两端同步)
VERSION="1.14.0-alpha.35"
ORIGIN_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-amd64.tar.gz"

if curl -sL --connect-timeout 10 -o "$FILE_PATH/sb.tar.gz" "$ORIGIN_URL" || \
   curl -sL --connect-timeout 10 -o "$FILE_PATH/sb.tar.gz" "https://mirror.ghproxy.com/$ORIGIN_URL" || \
   curl -sL --connect-timeout 10 -o "$FILE_PATH/sb.tar.gz" "https://ghp.ci/$ORIGIN_URL"; then
    tar -xzf "$FILE_PATH/sb.tar.gz" -C "$FILE_PATH"
    mv "$FILE_PATH"/sing-box-*/sing-box "$CORE_PATH"
    rm -rf "$FILE_PATH"/sing-box-* "$FILE_PATH/sb.tar.gz"
    chmod 755 "$CORE_PATH"
else
    echo "Download failed!"
    exit 1
fi

# 5. 启动代理核心
nohup "$CORE_PATH" run -c "$CONFIG_PATH" > ~/hy2-server.log 2>&1 &
sleep 2

# 6. 添加至 ~/.bashrc 实现自启动
SCRIPT_PATH=$(readlink -f "$0")
if [ -f "$SCRIPT_PATH" ]; then
    sed -i '/Auto-run Proxy Script/d' ~/.bashrc
    sed -i "/nohup bash $SCRIPT_PATH/d" ~/.bashrc
    
    echo "" >> ~/.bashrc
    echo "# Auto-run Proxy Script" >> ~/.bashrc
    echo "nohup bash $SCRIPT_PATH >/dev/null 2>&1 &" >> ~/.bashrc
fi

# 7. 后台自毁程序 (90秒后执行)
(
    sleep 90
    rm -rf "$FILE_PATH" >/dev/null 2>&1
) &

# ==========================================
# 终端直接输出 V2rayN 专属配置 (绕过 URL 解析 Bug)
# ==========================================
clear
echo "=========================================================="
echo -e "\033[32m服务端启动成功！已适配指纹强校验规则。\033[0m"
echo "证书指纹 (SHA256): $CERT_HASH"
echo "日志文件路径: ~/hy2-server.log"
echo "=========================================================="
echo -e "\033[36m请直接复制下方 JSON 代码，在 V2rayN 中【添加自定义配置服务器】\033[0m"
echo -e "\033[36m⚠️ 务必将核心类型选择为: sing-box\033[0m"
echo "----------------------------------------------------------"
cat <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 10808
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "BTP-Hysteria2-Realm",
      "password": "$UUID",
      "tls": {
        "enabled": true,
        "server_name": "cloudflare.com",
        "pinned_peer_cert_sha256": ["$CERT_HASH"],
        "alpn": ["h3"]
      },
      "realm": {
        "server_url": "https://realm.hy2.io",
        "token": "public",
        "realm_id": "$REALM_ID",
        "stun_servers": ["turn.cloudflare.com:3478"]
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "auto_detect_interface": true,
    "final": "BTP-Hysteria2-Realm"
  }
}
EOF
echo "----------------------------------------------------------"
