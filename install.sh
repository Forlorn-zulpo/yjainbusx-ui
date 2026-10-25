#!/usr/bin/env bash
# x-ui-yg A/B 一键部署入口
# 仅面向全新 VPS；保留上游 install.sh 的安装流程，通过提示词自动回答安装选项。

set -Eeuo pipefail

UPSTREAM_URL="https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/install.sh"
USERNAME="zulpo"
PASSWORD="zulpo"
PATH_VALUE="zulpo"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

if [[ "${EUID}" -ne 0 ]]; then
  red "请使用 root 运行本脚本。"
  exit 1
fi

if [[ -e /usr/local/x-ui/x-ui || -e /etc/systemd/system/x-ui.service || -e /etc/init.d/x-ui ]]; then
  red "检测到系统可能已经安装 x-ui。为避免覆盖现有配置，本脚本停止运行。"
  echo "请先确认现有安装情况；本脚本面向全新 VPS。"
  exit 1
fi

echo "=============================================="
echo "       x-ui-yg 一键部署（A / B 方案）"
echo "=============================================="
echo "A. 全自动：用户名 zulpo，密码 zulpo，端口 8843，路径 zulpo"
echo "B. 自定义端口：用户名 zulpo，密码 zulpo，路径 zulpo"
read -r -p "请选择 A 或 B [默认 A]：" MODE
MODE="${MODE:-A}"
MODE="${MODE^^}"

case "$MODE" in
  A) AUTO_PORT=8843 ;;
  B)
    while true; do
      read -r -p "请输入面板端口（1-65535）：" AUTO_PORT
      if [[ "$AUTO_PORT" =~ ^[0-9]+$ ]] && (( AUTO_PORT >= 1 && AUTO_PORT <= 65535 )); then
        break
      fi
      red "端口必须是 1 到 65535 之间的数字。"
    done
    ;;
  *)
    red "选项无效，请输入 A 或 B。"
    exit 1
    ;;
esac

if command -v ss >/dev/null 2>&1; then
  if ss -H -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "([:.])${AUTO_PORT}$"; then
    red "端口 ${AUTO_PORT} 当前已被占用。请释放端口后重试。"
    exit 1
  fi
else
  yellow "警告：未找到 ss，无法预先检查端口占用；原安装程序仍会执行自己的端口检查。"
fi

WORK_DIR="$(mktemp -d /tmp/xuiyg-once.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
UPSTREAM_FILE="$WORK_DIR/install.upstream.sh"
AUTO_FILE="$WORK_DIR/install.auto.sh"

green "正在下载上游 x-ui-yg 安装脚本……"
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 2 --connect-timeout 15 "$UPSTREAM_URL" -o "$UPSTREAM_FILE"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$UPSTREAM_FILE" "$UPSTREAM_URL"
else
  red "系统没有 curl 或 wget，无法下载上游安装脚本。"
  exit 1
fi

if [[ ! -s "$UPSTREAM_FILE" ]] || ! grep -q 'serinstall()' "$UPSTREAM_FILE" || ! grep -q 'userinstall()' "$UPSTREAM_FILE"; then
  red "下载文件为空或内容与预期不符；为避免运行错误脚本，已停止。"
  exit 1
fi

# 只在上游脚本末尾追加自动回答逻辑；上游主体安装函数保持原样。
# 同时验证最后一行，避免因上游文件结构变化而错误改写。
if [[ "$(tail -n 1 "$UPSTREAM_FILE" | tr -d '\r')" != "show_menu" ]]; then
  red "上游脚本末尾结构已变化，自动化兼容检查未通过。"
  echo "为避免误操作，本次停止；请检查上游 install.sh 后再更新本脚本。"
  exit 1
fi

# 删除原始末尾的首次 show_menu 调用，再追加自动化 readp 和 show_menu。
sed '$d' "$UPSTREAM_FILE" > "$AUTO_FILE"

cat >> "$AUTO_FILE" <<'AUTOMATION_EOF'

# ---- x-ui-yg 一键部署自动回答层（上游安装函数未修改）----
AUTO_PORT="__AUTO_PORT__"
AUTO_MENU_COUNT=0

readp() {
  local prompt="${1-}"
  local var="${2-}"
  local answer=""

  case "$prompt" in
    *"请输入数字【0-14】"*)
      if [[ "$AUTO_MENU_COUNT" -eq 0 ]]; then
        answer="1"   # 首次主菜单：一键安装
      else
        answer="0"   # 安装完成后退出菜单，避免再次选择安装
      fi
      AUTO_MENU_COUNT=$((AUTO_MENU_COUNT + 1))
      ;;
    *"是否开放端口，关闭防火墙"*)
      # 安全默认：不关闭防火墙、不清空 iptables 规则。
      # 原脚本按回车或输入 1 会执行 close()，可能关闭防火墙并清空规则。
      answer="2"
      ;;
    *"设置 x-ui 登录用户名"*)
      answer="zulpo"
      ;;
    *"设置 x-ui 登录密码"*)
      answer="zulpo"
      ;;
    *"设置 x-ui 登录端口"* )
      answer="$AUTO_PORT"
      ;;
    *"自定义端口:"*)
      echo >&2
      echo "自动化停止：端口 $AUTO_PORT 被原脚本判定为占用，请检查后重新运行。" >&2
      exit 1
      ;;
    *"设置 x-ui 登录根路径"*)
      answer="zulpo"
      ;;
    *"设置 x-ui 登录方式"*)
      answer=""       # 回车：保持 HTTP，不启用证书
      ;;
    *"按回车"* )
      answer=""       # 对明确的“按回车继续”提示按回车
      ;;
    *)
      # 遇到未知提示不猜答案，交由操作者确认。
      printf "%b" "$(yellow "$prompt")"
      read -r answer
      ;;
  esac

  printf -v "$var" '%s' "$answer"
}

show_menu
AUTOMATION_EOF

# 安全地写入所选端口，不对其他脚本内容做替换。
sed -i "s/__AUTO_PORT__/${AUTO_PORT}/g" "$AUTO_FILE"
chmod 700 "$AUTO_FILE"

echo
green "自动化参数已准备："
echo "方案：$MODE"
echo "用户名：$USERNAME"
echo "密码：$PASSWORD"
echo "端口：$AUTO_PORT"
echo "路径：$PATH_VALUE"
echo
yellow "注意：为避免原脚本关闭防火墙/清空 iptables，本入口会选择“2：跳过防火墙修改”。"
yellow "请确保 VPS 服务商防火墙/安全组允许 TCP ${AUTO_PORT} 入站。"
yellow "固定密码 zulpo 较弱，公网部署存在被猜测风险；建议部署后尽快修改。"
echo
green "开始执行上游安装脚本。脚本会先处理依赖，再下载、安装并启动 x-ui；只有安装流程通过后才会配置账号和端口。"
echo

set +e
bash "$AUTO_FILE"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  red "安装脚本退出，退出码：$STATUS"
  exit "$STATUS"
fi

echo
green "上游安装流程已结束。请根据上方输出确认 x-ui 服务状态和登录地址。"
