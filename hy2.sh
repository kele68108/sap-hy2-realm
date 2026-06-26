#!/usr/bin/env bash
# ==========================================
# 卸载逻辑：运行 bash hy2.sh uninstall 触发
# ==========================================
if [ "$1" == "uninstall" ]; then
    echo "[SYSTEM] 开始执行 hy2 卸载程序..."
    # 1. 杀掉占用 8343 UDP 端口的进程
    fuser -k -9 8343/udp >/dev/null 2>&1
    lsof -ti:8343 | xargs kill -9 >/dev/null 2>&1
    # 2. 清理残留文件和日志
    rm -rf ./tmp_hy2 ~/sing-box-client.json ~/hy2-server.log >/dev/null 2>&1
    # 3. 抹除 ~/.bashrc 中的自启项 (匹配 hy2.sh)
    sed -i '/hy2.sh/d' ~/.bashrc
    sed -i '/Auto-run Proxy Script/d' ~/.bashrc
    echo "[SYSTEM] 卸载完成！hy2 已彻底从系统中清除。"
    exit 0
fi
# ==========================================
# 用户配置区 (移植自 argo 脚本的极限隐蔽模式 + 日志输出)
# ==========================================
FILE_PATH="./tmp_hy2"
UUID="6948adff-5e1e-4f52-9c9c-11b707390b8b"
PORT=8343
REALM_ID="sap-bas-sg-hy2-kele666"
# ==========================================

# --- 0. 防呆设计：自动清理旧进程，防止端口冲突 ---
fuser -k -9 $PORT/udp >/dev/null 2>&1
lsof -ti:$PORT | xargs kill -9 >/dev/null 2>&1

# --- 1. 环境准备 (每次生成新的随机二进制名称) ---
if [ ! -d "$FILE_PATH" ]; then
    mkdir -p "$FILE_PATH/cert"
else
    rm -rf "$FILE_PATH"/* 2>/dev/null
    mkdir -p "$FILE_PATH/cert"
fi

CORE_NAME=$(tr -dc a-z </dev/urandom | head -c 6)
CORE_PATH="$FILE_PATH/$CORE_NAME"
CONFIG_PATH="$FILE_PATH/config.json"
CLIENT_PATH="$HOME/sing-box-client.json" # 客户端文件放在根目录，防止被90秒清理掉

# --- 2. 签发临时 TLS 证书 ---
openssl ecparam -genkey -name prime256v1 -out "$FILE_PATH/cert/private.key" 2>/dev/null
openssl req -new -x509 -days 36500 -key "$FILE_PATH/cert/private.key" -out "$FILE_PATH/cert/cert.pem" -subj "/CN=cloudflare.com" 2>/dev/null

# --- 3. 生成服务端 JSON 配置 (纯直连 + INFO日志) ---
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

# --- 4. 生成本地客户端单文件配置 (Sing-box 1.14.0 纯净版) ---
cat <<EOF > "$CLIENT_PATH"
{
  "log": {
    "level": "info",
    "timestamp": true
  },
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
      "tag": "Hysteria2-Realm",
      "password": "$UUID",
      "tls": {
        "enabled": true,
        "server_name": "cloudflare.com",
        "insecure": true,
        "alpn": ["h3"]
      },
      "realm": {
        "server_url": "https://realm.hy2.io",
        "token": "public",
        "realm_id": "$REALM_ID",
        "stun_servers": ["turn.cloudflare.com:3478"]
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
    "auto_detect_interface": true,
    "final": "Hysteria2-Realm"
  }
}
EOF

# --- 5. 下载核心组件 (Sing-box) ---
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

# --- 6. 启动代理核心 (将日志输出到宿主目录) ---
# 注意这里的改动：> ~/hy2-server.log
nohup "$CORE_PATH" run -c "$CONFIG_PATH" > ~/hy2-server.log 2>&1 &
sleep 2

# --- 7. 添加至 ~/.bashrc 实现自启动 ---
SCRIPT_PATH=$(readlink -f "$0")
if [ -f "$SCRIPT_PATH" ]; then
    # 清理掉之前我们加过的各种钩子，确保干净
    sed -i '/Auto-run Hysteria2 Realm for SAP BAS/d' ~/.bashrc
    sed -i '/pgrep -f .sb-core run./d' ~/.bashrc
    
    if ! grep -q "bash $SCRIPT_PATH" ~/.bashrc; then
        echo "" >> ~/.bashrc
        echo "# Auto-run Proxy Script" >> ~/.bashrc
        echo "nohup bash $SCRIPT_PATH >/dev/null 2>&1 &" >> ~/.bashrc
        echo "=================================================="
        echo "已成功将本脚本写入 ~/.bashrc，实现登录/开机自启"
        echo "=================================================="
    fi
fi

# --- 8. 后台自动隐藏清理文件 (90秒后执行) ---
(
    sleep 90
    rm -rf "$FILE_PATH" >/dev/null 2>&1
    clear
    echo "脚本运行完毕！"
    echo "所有配置文件已执行90秒后自毁!"
) &

echo ""
echo "=================================================="
echo "客户端配置已保存到: ~/Hysteria2-Realm.json"
echo "日志输出已保存到: ~/Hysteria2-Realm.log"
echo ""
echo "💡 查看实时日志请执行命令："
echo "tail -f ~/Hysteria2-Realm.log"
echo ""
echo "❌ 脚本卸载请执行命令："
echo "bash hy2.sh uninstall"
echo "=================================================="
