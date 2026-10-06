#!/usr/bin/env bash
# 发布前脱敏扫描：确保目录内无任何个人凭据 / 账号 / 私有 IP 泄漏
set -uo pipefail

TARGET="${1:-.}"
FAIL=0

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
hit() { echo "${RED}✗ LEAK${RST}  $1  →  $2"; FAIL=1; }
ok()  { echo "${GRN}✓${RST} $1"; }

echo "扫描目录: $TARGET"
echo "────────────────────────────────────────"

# 1. 已知本轮真实值

# 个人敏感值扫描：值从环境变量传入，不写死在脚本里
# 用法：VNC_PW=xxx GH_USER=xxx ./preflight.sh .
# 这样脚本本身可以安全开源，不会泄露任何人的真实凭据
echo "────────────────────────────────────────"
echo "个人敏感值扫描:"

check_env() {
  local label="$1" envname="$2" val
  val="${!envname:-}"
  if [[ -z "$val" ]]; then
    printf "  - %s (未设置 %s, 跳过)\n" "$label" "$envname"
    return
  fi
  local out
  out="$(grep -rInF -- "$val" "$TARGET" 2>/dev/null \
         | grep -v "preflight.sh:" | head -3)"
  if [[ -n "$out" ]]; then hit "$label" "$(echo "$out" | head -1)"; else ok "$label"; fi
}

check_env "VNC 密码"     VNC_PW
check_env "Codespace 名" CODESPACE_NAME
check_env "临时仓库名"   TMP_REPO
check_env "GitHub 账号"  GH_USER
check_env "真实出口 IP"  EXIT_IP
check_env "内部 DNS"     CS_DNS

# 2. 模式扫描
echo "────────────────────────────────────────"
echo "模式扫描:"

pat() {
  local label="$1" re="$2" hint="$3"
  local out
  out="$(grep -rInE -- "$re" "$TARGET" 2>/dev/null | grep -v "preflight.sh:" | head -4)"
  if [[ -n "$out" ]]; then hit "$label" "$(echo "$out" | head -1)"; else ok "$label"; fi
}

pat "邮箱地址"     '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'          "换成占位符或删除"
pat "GitHub token" 'gh[pousr]_[A-Za-z0-9]{20,}'                            "绝不能提交"
pat "AWS key"      'AKIA[0-9A-Z]{16}'                                      "绝不能提交"
pat "私钥块"       'BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY'            "绝不能提交"
pat "本机绝对路径" '/(Users|home)/[A-Za-z0-9._-]+/(Library|workspace|\.ssh|\.aws)'  "改成相对路径或 <user>"
pat "Google API"   'AIza[0-9A-Za-z_-]{35}'                                 "绝不能提交"
pat "Slack token"  'xox[baprs]-[0-9A-Za-z-]{10,}'                          "绝不能提交"
pat "sk- 密钥"     'sk-[A-Za-z0-9]{32,}'                                    "绝不能提交"
pat "长十六进制串" '\b[0-9a-f]{32,}\b'                                      "确认非凭据"

# 3. VNC_PW 硬编码检查
echo "────────────────────────────────────────"
if grep -rIn 'VNC_PW=123456' "$TARGET" 2>/dev/null | grep -v "preflight.sh:" | head -3 | grep -q .; then
  hit "弱 VNC 密码" "$(grep -rIn 'VNC_PW=123456' "$TARGET" 2>/dev/null | grep -v "preflight.sh:" | head -1)"
else
  ok "无弱 VNC 密码硬编码"
fi

# 4. 域名白名单检查
echo "────────────────────────────────────────"
FOREIGN=$(grep -rInoE 'https?://[a-zA-Z0-9.-]+' "$TARGET" 2>/dev/null \
  | grep -oE 'https?://[a-zA-Z0-9.-]+' | sort -u \
  | grep -vE 'github\.com|githubusercontent\.com|cli\.github\.com|localhost|127\.0\.0\.1|ipinfo\.io|example\.com|matrix\.org|$(printf '')|openssl\.org|curl\.se')
if [[ -n "$FOREIGN" ]]; then
  echo "${YEL}! 非白名单域名（请人工确认是否需要保留）:${RST}"
  echo "$FOREIGN" | head -8
else
  ok "域名均在白名单内"
fi

echo "────────────────────────────────────────"
if [[ $FAIL -eq 0 ]]; then
  echo "${GRN}✓ 未发现泄漏，可发布${RST}"
  exit 0
else
  echo "${RED}✗ 发现泄漏，修复后再发布${RST}"
  exit 1
fi
