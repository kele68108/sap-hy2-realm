#!/usr/bin/env bash
# ==========================================
# Hysteria2 Realm 节点部署脚本 (SAP BAS)
# wget/curl 拉起 sing-box 最新 1.14.0 预发布版，构建 realm 打洞节点
# 卸载：运行 bash sap-bas-hy2.sh uninstall 触发
# ==========================================
if [ "$1" == "uninstall" ]; then
    echo "[SYSTEM] 开始执行 hy2 卸载程序..."
    # 1. 杀掉占用 8343 UDP 端口的进程
    fuser -k -9 8343/udp >/dev/null 2>&1
    lsof -ti:8343 | xargs kill -9 >/dev/null 2>&1
    # 2. 清理残留文件和日志
    rm -rf ./tmp_hy2 ~/sing-box-client.json ~/hy2-server.log >/dev/null 2>&1
    # 3. 抹除 ~/.bashrc 中的自启项
    sed -i '/hy2.sh/d' ~/.bashrc
    sed -i '/sap-bas-hy2.sh/d' ~/.bashrc
    sed -i '/Auto-run Proxy Script/d' ~/.bashrc
    echo "[SYSTEM] 卸载完成！hy2 已彻底从系统中清除。"
    exit 0
fi
# ==========================================
# 用户配置区
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
CLIENT_PATH="$HOME/sing-box-client.json"

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
        "stun_servers": [ "turn.cloudflare.com:3478", "stun.nextcloud.com:3478", "stun.sip.us:3478" ],
        "ip_version": 4
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
        "stun_servers": ["turn.cloudflare.com:3478", "stun.nextcloud.com:3478", "stun.sip.us:3478"],
        "ip_version": 4
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

# --- 5. 下载核心组件 (Sing-box 最新 1.14.0 预发布版) ---
# realm 协议仅在 1.14.0+ 支持，稳定版 1.13.x 不含 realm，故取 1.14.0 系列最新。
# 动态从 GitHub API 获取最新版本号，失败时 fallback 到硬编码版本。
SB_VERSION=$(python3 -c "
import urllib.request, json, sys
try:
    req = urllib.request.Request(
        'https://api.github.com/repos/SagerNet/sing-box/releases',
        headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'curl/8.0'}
    )
    data = json.loads(urllib.request.urlopen(req, timeout=10).read())
    for r in data:
        t = r.get('tag_name', '')
        if t.startswith('v1.14'):
            print(t.lstrip('v'))
            sys.exit(0)
except Exception:
    pass
" 2>/dev/null)
SB_VERSION="${SB_VERSION:-1.14.0-beta.17}"
echo "[INFO] sing-box 版本: $SB_VERSION"

ORIGIN_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-amd64.tar.gz"

if curl -sL --connect-timeout 15 -o "$FILE_PATH/sb.tar.gz" "$ORIGIN_URL" || \
   curl -sL --connect-timeout 15 -o "$FILE_PATH/sb.tar.gz" "https://mirror.ghproxy.com/$ORIGIN_URL" || \
   curl -sL --connect-timeout 15 -o "$FILE_PATH/sb.tar.gz" "https://ghp.ci/$ORIGIN_URL"; then
    tar -xzf "$FILE_PATH/sb.tar.gz" -C "$FILE_PATH"
    mv "$FILE_PATH"/sing-box-*/sing-box "$CORE_PATH"
    rm -rf "$FILE_PATH"/sing-box-* "$FILE_PATH/sb.tar.gz"
    chmod 755 "$CORE_PATH"
else
    echo "[ERROR] sing-box 下载失败！请检查网络或手动指定版本。"
    echo "尝试版本: $SB_VERSION"
    echo "URL: $ORIGIN_URL"
    exit 1
fi

# --- 6. 启动代理核心 (日志输出到宿主目录) ---
nohup "$CORE_PATH" run -c "$CONFIG_PATH" > ~/hy2-server.log 2>&1 &
sleep 2

# --- 7. 添加至 ~/.bashrc 实现自启动 ---
SCRIPT_PATH=$(readlink -f "$0")
if [ -f "$SCRIPT_PATH" ]; then
    # 清理掉之前加过的各种钩子，确保干净
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

echo ""
echo "=================================================="
echo "sing-box 版本:  $SB_VERSION"
echo "核心路径:       $CORE_PATH"
echo "服务端配置:     $CONFIG_PATH"
echo "客户端配置已保存到: ~/sing-box-client.json"
echo "日志输出已保存到:   ~/hy2-server.log"
echo ""
echo "💡 查看实时日志请执行命令："
echo "tail -f ~/hy2-server.log"
echo ""
echo "❌ 脚本卸载请执行命令："
echo "bash $0 uninstall"
echo "=================================================="
