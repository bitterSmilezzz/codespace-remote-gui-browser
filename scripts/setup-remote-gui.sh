#!/usr/bin/env bash
#
# 在 GitHub Codespaces 上部署一个可远程访问的图形浏览器（KasmVNC + Chrome）
# 已处理无 GPU 环境下 Zink 导致的 SIGTRAP 崩溃。
#
# 用法：
#   ./setup-remote-gui.sh --repo <owner>/<repo> --region WestUs3
#   ./setup-remote-gui.sh --repo <owner>/<repo> --region WestUs3 --local-port 8443
#
set -euo pipefail

REPO=""
REGION="WestUs3"
LOCAL_PORT="8443"
MACHINE="basicLinux32gb"
CS_NAME="remote-gui"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)       REPO="$2"; shift 2 ;;
    --region)     REGION="$2"; shift 2 ;;
    --local-port) LOCAL_PORT="$2"; shift 2 ;;
    --machine)    MACHINE="$2"; shift 2 ;;
    --name)       CS_NAME="$2"; shift 2 ;;
    -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
    *)            die "未知参数: $1" ;;
  esac
done

[[ -n "$REPO" ]] || die "必须提供 --repo <owner>/<repo>"

# GITHUB_TOKEN 优先级高于 keyring，会阻止 gh auth refresh 并干扰 codespace scope
GH=(env -u GITHUB_TOKEN gh)

# ---------------------------------------------------------------- 0. 前置检查
info "检查 GitHub CLI"
command -v gh >/dev/null || die "未安装 gh: https://cli.github.com"
gh --version | head -1

if ! "${GH[@]}" auth status >/dev/null 2>&1; then
  die "gh 未登录，请先运行: gh auth login"
fi

# codespace scope 探测
if ! "${GH[@]}" codespace list >/dev/null 2>&1; then
  cat >&2 <<'EOF'

token 缺少 codespace scope。请运行：
  gh auth refresh -h github.com -s codespace

若提示 "The value of the GITHUB_TOKEN environment variable is being used"，
在当前终端先执行 unset GITHUB_TOKEN 再重试。
EOF
  exit 1
fi

# ---------------------------------------------------------------- 1. 生成密码
info "生成 VNC 强密码"
VNC_PW="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
PW_FILE="$(mktemp -u /tmp/remote-gui-pw.XXXXXX)"
printf '%s' "$VNC_PW" > "$PW_FILE"
chmod 600 "$PW_FILE"
info "密码已存: $PW_FILE"

# ---------------------------------------------------------------- 2. 建 Codespace
info "在 $REGION 创建 Codespace（仓库需已有 main 分支）"
CS_OUT="$("${GH[@]}" codespace create --repo "$REPO" --machine "$MACHINE" \
         --location "$REGION" --display-name "$CS_NAME" 2>&1)" || {
  echo "$CS_OUT"
  if grep -q "no such machine" <<<"$CS_OUT"; then
    die "机器类型 $MACHINE 不存在，请从上方 Available machines 列表中选一个"
  fi
  die "创建失败（仓库是否为空？空仓库需先推送一个 commit）"
}
CS="$(tail -1 <<<"$CS_OUT" | tr -d '[:space:]')"
info "Codespace: $CS"

# 核对真实落点（请求的 region 可能与实际不符）
REAL_REGION="$("${GH[@]}" api "repos/$REPO/codespaces" \
  --jq ".codespaces[] | select(.name==\"$CS\") | .location" 2>/dev/null || echo "unknown")"
[[ "$REAL_REGION" != "$REGION" ]] && \
  echo "  注意: 请求 $REGION，实际落在 $REAL_REGION" || true

info "等待实例就绪"
for i in $(seq 1 25); do
  ST="$("${GH[@]}" codespace list --json name,state \
        --jq ".[] | select(.name==\"$CS\") | .state" 2>/dev/null)"
  [[ "$ST" == "Available" ]] && break
  sleep 12
done
[[ "$ST" == "Available" ]] || die "实例未就绪（当前 $ST）"

cssh() { "${GH[@]}" codespace ssh -c "$CS" -- bash -s; }

# ---------------------------------------------------------------- 3. Chrome 容器
info "拉取 kasmweb/chrome 镜像（1-2GB，需数分钟）"
cssh <<EOF
set -e
docker run -d --name cloud-browser -p 6901:6901 -e VNC_PW=${VNC_PW} kasmweb/chrome:1.15.0
EOF

# ---------------------------------------------------------------- 4. Zink 修复
info "注入软件渲染启动脚本（绕开无 GPU 下的 Zink 崩溃）"
cssh <<'EOF'
set -e
docker exec -u kasm-user -e HOME=/home/kasm-user cloud-browser bash -c '
cat > /home/kasm-user/chrome-soft.sh <<"INNER"
#!/bin/bash
export XDG_RUNTIME_DIR=/tmp/xdg-$USER
mkdir -p $XDG_RUNTIME_DIR && chmod 700 $XDG_RUNTIME_DIR
exec /opt/google/chrome/google-chrome \
  --password-store=basic --no-sandbox \
  --disable-gpu --use-gl=angle --use-angle=swiftshader \
  --disable-dev-shm-usage --disable-features=Vulkan \
  --user-data-dir=/home/kasm-user/.config/google-chrome \
  --no-first-run --start-maximized \
  --simulate-outdated-no-au="Tue, 31 Dec 2099 23:59:59 GMT" "$@"
INNER
chmod +x /home/kasm-user/chrome-soft.sh'
EOF

info "启动 Chrome 并验证（期望进程数>1 且 zink 错误=0）"
cssh <<'EOF'
set -e
docker exec -d -u kasm-user -e DISPLAY=:1 -e HOME=/home/kasm-user \
  cloud-browser /home/kasm-user/chrome-soft.sh
EOF
sleep 15
NPROC="$(cssh <<< 'docker exec cloud-browser sh -c "pgrep -c chrome"' 2>/dev/null | tail -1 | tr -dc '0-9')"
NZINK="$(cssh <<< 'docker logs --tail 25 cloud-browser 2>&1 | grep -ic zink || true' 2>/dev/null | tail -1 | tr -dc '0-9')"
[[ "${NPROC:-0}" -gt 1 ]] || { echo "Chrome 未起来（进程数=${NPROC:-0}）"; exit 1; }
[[ "${NZINK:-1}" == "0" ]] || echo "  警告: 仍检测到 zink 错误 ${NZINK} 次，Chrome 可能仍会崩"
info "Chrome 进程 ${NPROC}，zink 错误 ${NZINK}"

# ---------------------------------------------------------------- 5. HTTPS 反代
info "安装 nginx 并终止 TLS（KasmVNC 只服务 HTTPS）"
cssh <<'EOF'
set -e
sudo apt-get update -qq
sudo apt-get install -y -qq nginx openssl
sudo mkdir -p /etc/nginx/conf.d
mkdir -p /tmp/rtls && cd /tmp/rtls
openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
  -keyout key.pem -out cert.pem -subj "/CN=remote.local" 2>/dev/null
sudo cp cert.pem /etc/ssl/cert.pem
sudo cp key.pem  /etc/ssl/key.pem
sudo tee /etc/nginx/conf.d/vnc.conf >/dev/null <<'NGINX'
server {
    listen 443 ssl;
    server_name _;
    ssl_certificate     /etc/ssl/cert.pem;
    ssl_certificate_key /etc/ssl/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    location / {
        proxy_pass https://127.0.0.1:6901;
        proxy_ssl_verify      off;
        proxy_ssl_server_name on;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       $host;
        proxy_set_header X-Real-IP  $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
    }
}
NGINX
sudo nginx -t >/dev/null 2>&1
sudo nginx -s stop 2>/dev/null || true
sleep 2
sudo nginx
EOF

CODE="$(cssh <<EOF
curl -sk -u kasm_user:${VNC_PW} -o /dev/null -w '%{http_code}' --max-time 15 https://127.0.0.1:443/
EOF
 2>/dev/null | tail -1 | tr -dc '0-9')"
[[ "$CODE" == "200" ]] || die "反代验证失败 HTTP=${CODE:-无响应}（200=正常，401=服务在但要认证，502=回源协议错或443被占）"
info "反代验证通过 (HTTP 200)"

# ---------------------------------------------------------------- 6. 端口转发
info "建立端口转发 远端443 -> 本地${LOCAL_PORT}（长驻，需 nohup）"
nohup "${GH[@]}" codespace ports forward -c "$CS" "443:${LOCAL_PORT}" \
  >"/tmp/forward-${LOCAL_PORT}.log" 2>&1 &
sleep 20
"${GH[@]}" codespace ports -c "$CS" || true

# ---------------------------------------------------------------- 完成
IP="$(cssh <<< 'curl -s --max-time 10 https://ipinfo.io/json' 2>/dev/null \
      | grep -oE '"ip": *"[^"]+"' | head -1 | grep -oE '[0-9.]+' || echo '?')"
GEO="$(cssh <<< 'curl -s --max-time 10 https://ipinfo.io/json' 2>/dev/null \
      | grep -oE '"country": *"[^"]+"' | head -1 | sed 's/.*: *"//;s/"//' || echo '?')"

cat <<EOF

============================================================
部署完成
============================================================
Codespace : $CS
实际区域  : $REAL_REGION
出口 IP   : $IP ($GEO)
本机地址  : https://127.0.0.1:${LOCAL_PORT}
VNC 用户  : kasm_user
VNC 密码  : $(cat "$PW_FILE")
密码文件  : $PW_FILE

浏览器打开上面的本机地址，自签证书点「继续访问」。
先在云端窗口内开 https://ipinfo.io 确认国家，再开目标站点。

KasmVNC 坐标有偏移，点不动时用 Tab + Enter，或用左侧「按键」面板。

收尾：
  ${GH[*]} codespace delete -c $CS --yes
  ${GH[*]} repo delete $REPO --yes
  rm -f "$PW_FILE"
============================================================
EOF
