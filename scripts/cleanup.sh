#!/usr/bin/env bash
# 清理远程图形浏览器环境的全部资源
set -euo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }
GH=(env -u GITHUB_TOKEN gh)

CS_NAME="${1:-}"
REPO="${2:-}"

[[ -n "$CS_NAME" ]] || die "用法: $0 <codespace-name> [owner/repo]"

echo "==> 停止容器"
"${GH[@]}" codespace ssh -c "$CS_NAME" -- \
  "docker stop cloud-browser 2>/dev/null; docker stop nginx 2>/dev/null; echo done" || true

echo "==> 删除 Codespace"
"${GH[@]}" codespace delete -c "$CS_NAME" --yes

if [[ -n "$REPO" ]]; then
  echo "==> 删除临时仓库 $REPO"
  "${GH[@]}" repo delete "$REPO" --yes || echo "  （跳过，可能已删除或无权限）"
fi

echo "==> 清理本机密码文件与日志"
rm -f /tmp/remote-gui-pw.* /tmp/forward-*.log

echo "完成。"
