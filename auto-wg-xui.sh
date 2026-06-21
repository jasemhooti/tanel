#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'
LINE="================================================================"
THIN="────────────────────────────────────────────────────────────────"

show_error()   { echo -e "${RED}❌ $1${NC}";    log "ERROR" "$1"; }
show_success() { echo -e "${GREEN}✅ $1${NC}";  log "OK"    "$1"; }
show_info()    { echo -e "${YELLOW}🔹 $1${NC}"; log "INFO"  "$1"; }
show_header()  { echo -e "${CYAN}$LINE\n   $1\n$LINE${NC}"; }
show_step()    { echo -e "\n${BLUE}${THIN}\n   $1\n${THIN}${NC}"; }
show_note()    { echo -e "${YELLOW}   ℹ️  $1${NC}"; }
show_ask()     { echo -e "${GREEN}   ❓ $1${NC}"; }

LOG_FILE="/var/log/wg-xui.log"
TG_CONFIG="/etc/wg-xui/telegram.conf"
XUI_DB="/etc/x-ui/x-ui.db"

log() {
  local level="$1" msg="$2"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
  if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    mv "${LOG_FILE}.2" "${LOG_FILE}.3" 2>/dev/null || true
    mv "${LOG_FILE}.1" "${LOG_FILE}.2" 2>/dev/null || true
    mv "$LOG_FILE"     "${LOG_FILE}.1"
    touch "$LOG_FILE"
  fi
}

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ لطفاً این اسکریپت را با دسترسی root اجرا کنید${NC}"
  exit 1
fi

detect_setup() {
  if command -v awg-quick &>/dev/null; then
    WG_CMD="awg-quick"; WG_IFACE="awg0"; WG_CONF_DIR="/etc/amnezia/amneziawg"
  else
    WG_CMD="wg-quick";  WG_IFACE="wg0";  WG_CONF_DIR="/etc/wireguard"
  fi
}

setup_firewall() {
  # اطمینان از نصب ufw (ممکن است توسط iptables-persistent حذف شده باشد)
  if ! command -v ufw &>/dev/null; then
    show_info "نصب ufw..."
    wait_apt_lock
    apt install -y ufw
  fi
  for port in "$@"; do
    ufw allow "$port"
  done
  ufw allow ssh
  ufw --force enable
  show_success "فایروال تنظیم شد"
}

# ─────────────────────────────────────────────
# توابع تلگرام
# ─────────────────────────────────────────────
tg_load() { [ -f "$TG_CONFIG" ] && source "$TG_CONFIG" || true; }

tg_send() {
  tg_load
  [ -z "$TG_TOKEN" ] || [ -z "$TG_ADMIN_ID" ] && return 0
  curl -s --max-time 10 \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" -d "text=$1" -d "parse_mode=HTML" \
    -o /dev/null || true
}

tg_send_file() {
  tg_load
  [ -z "$TG_TOKEN" ] || [ -z "$TG_ADMIN_ID" ] && return 0
  curl -s --max-time 30 \
    "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
    -F "chat_id=${TG_ADMIN_ID}" -F "document=@$1" -F "caption=$2" \
    -o /dev/null || true
}

# ─────────────────────────────────────────────
# تنظیم ربات تلگرام
# ─────────────────────────────────────────────
setup_telegram() {
  show_step "تنظیم ربات تلگرام (اختیاری)"

  echo -e "
   ربات تلگرام به شما امکان می‌دهد:
   • اعلان‌های خودکار قطعی و ری‌استارت تونل را دریافت کنید
   • از طریق تلگرام تونل را مدیریت کنید
   • هر شب بکاپ خودکار X-UI به تلگرام ارسال شود

   ${YELLOW}برای ساخت ربات:${NC}
   ۱. در تلگرام @BotFather را جستجو کنید
   ۲. دستور /newbot را بزنید
   ۳. یک نام و username برای ربات انتخاب کنید
   ۴. توکن نمایش داده شده را کپی کنید (شکل: 123456789:ABC-xyz...)

   ${YELLOW}برای Chat ID:${NC}
   ۱. ربات @userinfobot را در تلگرام جستجو کنید
   ۲. /start بزنید — عدد «Id» نشان داده می‌شود همان Chat ID شماست

   ${RED}اگر ربات نمی‌خواهید فقط Enter بزنید تا رد شود.${NC}
"

  show_ask "توکن ربات را وارد کنید (یا Enter برای رد کردن):"
  read -p "   > " input_token
  if [ -z "$input_token" ]; then
    show_info "ربات تلگرام رد شد — بعداً می‌توانید اضافه کنید"
    return
  fi

  show_ask "Chat ID ادمین را وارد کنید (عدد شخصی شما از @userinfobot):"
  read -p "   > " input_admin_id
  if [ -z "$input_admin_id" ]; then
    show_info "ربات تلگرام رد شد"
    return
  fi

  # ذخیره توکن بدون تست آنلاین — سرور ایران قبل از وصل شدن تونل
  # به api.telegram.org دسترسی ندارد (فیلتر است)
  mkdir -p /etc/wg-xui
  cat > "$TG_CONFIG" <<EOF
TG_TOKEN="${input_token}"
TG_ADMIN_ID="${input_admin_id}"
EOF
  chmod 600 "$TG_CONFIG"
  show_success "اطلاعات ربات ذخیره شد"
  show_info "تست ارسال پیام بعد از وصل شدن تونل انجام می‌شود"
}

# ─────────────────────────────────────────────
# ساخت سرویس ربات تلگرام
# ─────────────────────────────────────────────
install_telegram_bot() {
  tg_load
  [ -z "$TG_TOKEN" ] && return 0

  show_info "نصب سرویس ربات تلگرام..."
  apt install -y python3 python3-pip -qq
  pip3 install requests -q

  detect_setup

  cat > /usr/local/bin/wg-tgbot.py <<PYEOF
#!/usr/bin/env python3
import requests, subprocess, os, time, shutil
from datetime import datetime

def _cfg(key):
    for l in open("/etc/wg-xui/telegram.conf"):
        if l.startswith(key):
            return l.split("=",1)[1].strip().strip('"')
    return ""

TOKEN    = _cfg("TG_TOKEN")
ADMIN_ID = int(_cfg("TG_ADMIN_ID"))
WG_CMD   = "${WG_CMD}"
WG_IFACE = "${WG_IFACE}"
LOG_FILE = "/var/log/wg-xui.log"
XUI_DB   = "/etc/x-ui/x-ui.db"
API      = f"https://api.telegram.org/bot{TOKEN}"

def send(text, chat_id=ADMIN_ID):
    try:
        requests.post(f"{API}/sendMessage",
                      data={"chat_id": chat_id, "text": text, "parse_mode": "HTML"},
                      timeout=10)
    except Exception:
        pass

def send_file(path, caption="", chat_id=ADMIN_ID):
    try:
        with open(path, "rb") as f:
            requests.post(f"{API}/sendDocument",
                          data={"chat_id": chat_id, "caption": caption},
                          files={"document": f}, timeout=30)
    except Exception:
        pass

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return (r.stdout + r.stderr).strip() or "اجرا شد"
    except Exception as e:
        return f"خطا: {e}"

def backup_xui():
    if not os.path.exists(XUI_DB):
        return None
    dst = f"/tmp/x-ui-backup-{datetime.now().strftime('%Y%m%d_%H%M%S')}.db"
    shutil.copy2(XUI_DB, dst)
    return dst

HELP = """📋 <b>دستورات ربات:</b>

/status — وضعیت تونل
/restart — ری‌استارت تونل
/restart_xui — ری‌استارت X-UI
/start — شروع تونل
/stop — توقف تونل
/log — آخرین ۵۰ خط لاگ
/test — تست اتصال (ping، اینترنت، X-UI)
/backup — ارسال فوری بکاپ X-UI
/help — این راهنما"""

def cmd_status():
    out = run(f"systemctl status {WG_CMD}@{WG_IFACE} --no-pager -l | head -20")
    return f"📊 <b>وضعیت تونل:</b>\n<pre>{out}</pre>"

def cmd_test():
    ping  = run("ping -c 3 -W 4 10.8.0.1")
    inet  = run("curl -s --max-time 8 https://1.1.1.1 -o /dev/null -w '%{http_code}'")
    xui   = run("systemctl is-active x-ui")
    p = '✅' if '0%' in ping  else '❌'
    i = '✅' if '200' in inet else '❌'
    x = '✅' if 'active' in xui else '❌'
    return f"🧪 <b>نتیجه تست:</b>\n{p} ping سرور خارجی\n{i} اینترنت از طریق تونل\n{x} سرویس X-UI"

COMMANDS = {
    "/help":        lambda: HELP,
    "/status":      cmd_status,
    "/restart":     lambda: f"🔄 تونل ری‌استارت شد\n<pre>{run(f'systemctl restart {WG_CMD}@{WG_IFACE}')}</pre>",
    "/restart_xui": lambda: f"🔄 X-UI ری‌استارت شد\n<pre>{run('systemctl restart x-ui')}</pre>",
    "/start":       lambda: f"▶️ تونل شروع شد\n<pre>{run(f'systemctl start {WG_CMD}@{WG_IFACE}')}</pre>",
    "/stop":        lambda: f"⏹ تونل متوقف شد\n<pre>{run(f'systemctl stop {WG_CMD}@{WG_IFACE}')}</pre>",
    "/test":        cmd_test,
}

def handle_log(chat_id):
    try:
        lines = open(LOG_FILE).readlines()[-50:]
        text  = "".join(lines) or "لاگ خالی است"
        send(f"📄 <b>آخرین ۵۰ خط لاگ:</b>\n<pre>{text[-3500:]}</pre>", chat_id)
    except Exception as e:
        send(f"❌ {e}", chat_id)

def handle_backup(chat_id):
    send("⏳ در حال تهیه پشتیبان...", chat_id)
    dst = backup_xui()
    if dst:
        send_file(dst, f"💾 بکاپ X-UI — {datetime.now().strftime('%Y-%m-%d %H:%M')}", chat_id)
        os.remove(dst)
    else:
        send("❌ فایل دیتابیس X-UI یافت نشد", chat_id)

offset = 0
send("🚀 <b>ربات راه‌اندازی شد</b>\n" + HELP)

while True:
    try:
        r = requests.get(f"{API}/getUpdates",
                         params={"offset": offset, "timeout": 30}, timeout=35)
        for u in r.json().get("result", []):
            offset = u["update_id"] + 1
            msg  = u.get("message") or u.get("edited_message", {})
            if not msg:
                continue
            cid  = msg["chat"]["id"]
            text = msg.get("text", "").strip()
            if cid != ADMIN_ID:
                send("⛔ دسترسی ندارید", cid)
                continue
            if   text == "/log":    handle_log(cid)
            elif text == "/backup": handle_backup(cid)
            elif text in COMMANDS:  send(COMMANDS[text](), cid)
            else:                   send("❓ دستور نامشخص\n" + HELP, cid)
    except Exception:
        time.sleep(5)
PYEOF

  chmod +x /usr/local/bin/wg-tgbot.py

  cat > /etc/systemd/system/wg-tgbot.service <<EOF
[Unit]
Description=WireGuard Telegram Bot
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/wg-tgbot.py
Restart=always
RestartSec=10
StandardOutput=append:/var/log/wg-xui.log
StandardError=append:/var/log/wg-xui.log

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now wg-tgbot
  show_success "سرویس ربات تلگرام فعال شد"
}

# ─────────────────────────────────────────────
# پشتیبان‌گیری خودکار X-UI
# ─────────────────────────────────────────────
setup_xui_backup() {
  tg_load
  [ -z "$TG_TOKEN" ] && return 0

  cat > /usr/local/bin/wg-xui-backup <<'BKEOF'
#!/bin/bash
source /etc/wg-xui/telegram.conf 2>/dev/null || exit 0
XUI_DB="/etc/x-ui/x-ui.db"
[ -f "$XUI_DB" ] || exit 0
DST="/tmp/x-ui-backup-$(date '+%Y%m%d_%H%M%S').db"
cp "$XUI_DB" "$DST"
curl -s --max-time 30 \
  "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
  -F "chat_id=${TG_ADMIN_ID}" \
  -F "document=@${DST}" \
  -F "caption=💾 بکاپ خودکار X-UI — $(date '+%Y-%m-%d %H:%M')" \
  -o /dev/null
rm -f "$DST"
echo "$(date '+%Y-%m-%d %H:%M:%S') [BACKUP] x-ui backup sent" >> /var/log/wg-xui.log
BKEOF

  chmod +x /usr/local/bin/wg-xui-backup
  if ! crontab -l 2>/dev/null | grep -q "wg-xui-backup"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/wg-xui-backup") | crontab -
    show_success "پشتیبان‌گیری خودکار هر روز ساعت ۳ صبح تنظیم شد"
  fi
}

# ─────────────────────────────────────────────
# نصب AmneziaWG
# ─────────────────────────────────────────────
apt_locked() {
  fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend &>/dev/null
}

force_unlock_apt() {
  show_info "در حال متوقف کردن آپدیت خودکار اوبونتو..."
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  killall apt apt-get unattended-upgrade 2>/dev/null || true
  sleep 3
  # رفع قفل و بازیابی dpkg در صورت نیمه‌کاره ماندن
  rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend 2>/dev/null || true
  dpkg --configure -a 2>/dev/null || true
  show_success "قفل apt آزاد شد"
}

wait_apt_lock() {
  apt_locked || return 0
  show_info "یک فرآیند دیگر در حال استفاده از apt است (معمولاً آپدیت خودکار اوبونتو)"
  local i=0 pid pname
  while apt_locked; do
    sleep 5; ((i++)) || true
    # هر ۳۰ ثانیه وضعیت را گزارش بده
    if [ $((i % 6)) -eq 0 ]; then
      pid=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | tr -d ' ')
      pname=$(ps -o comm= -p "${pid:-0}" 2>/dev/null | head -1)
      show_info "هنوز قفل است (فرآیند: ${pname:-نامشخص}) — $((i*5)) ثانیه گذشت..."
    fi
    # بعد از ۹۰ ثانیه از کاربر بپرس
    if [ $i -ge 18 ]; then
      echo
      show_error "apt بعد از ۹۰ ثانیه هنوز قفل است."
      echo "   احتمالاً آپدیت خودکار اوبونتو (unattended-upgrades) در حال اجراست."
      show_ask "می‌خواهید این فرآیند را متوقف کنم تا نصب ادامه یابد؟ (y = متوقف کن / n = صبر می‌کنم):"
      read -p "   > " kill_choice
      if [ "$kill_choice" = "y" ] || [ "$kill_choice" = "Y" ]; then
        force_unlock_apt
        return 0
      fi
      i=0  # دوباره صبر کن
    fi
  done
  show_success "قفل apt آزاد شد"
}

install_amneziawg() {
  show_info "نصب AmneziaWG (ضد شناسایی توسط فیلترینگ)..."
  wait_apt_lock
  apt update -qq
  if ! command -v awg-quick &>/dev/null; then
    wait_apt_lock
    apt install -y software-properties-common
    add-apt-repository -y ppa:amnezia/ppa 2>/dev/null || true
    wait_apt_lock
    apt update -qq
    apt install -y amneziawg amneziawg-tools || {
      show_info "PPA در دسترس نیست، نصب WireGuard معمولی..."
      wait_apt_lock
      apt install -y wireguard-dkms wireguard-tools linux-headers-$(uname -r) git make gcc
    }
  fi
}

# ─────────────────────────────────────────────
# تست خودکار بعد از نصب
# ─────────────────────────────────────────────
run_post_install_test() {
  local role="$1" foreign_wg_ip="$2" report="" pass=0 fail=0

  show_step "تست خودکار بعد از نصب"
  detect_setup

  _check() {
    local label="$1" cmd="$2"
    if eval "$cmd" &>/dev/null; then
      echo -e "   ${GREEN}✅ $label${NC}"; log "TEST-OK" "$label"
      report+="✅ $label%0A"; ((pass++)) || true
    else
      echo -e "   ${RED}❌ $label${NC}"; log "TEST-FAIL" "$label"
      report+="❌ $label%0A"; ((fail++)) || true
    fi
  }

  _check "سرویس تونل فعال است"    "systemctl is-active --quiet ${WG_CMD}@${WG_IFACE}"
  _check "interface تونل بالا است"  "ip link show ${WG_IFACE}"

  if [ "$role" = "iran" ]; then
    _check "ارتباط با سرور خارجی (${foreign_wg_ip})" "ping -c 2 -W 4 ${foreign_wg_ip}"
    _check "دسترسی به اینترنت از طریق تونل"           "curl -s --max-time 8 https://1.1.1.1 -o /dev/null"
    _check "DNS کار می‌کند"                            "nslookup google.com 8.8.8.8"
    _check "سرویس 3X-UI فعال است"                     "systemctl is-active --quiet x-ui"
  fi

  if [ "$role" = "foreign" ]; then
    _check "IP Forwarding فعال است" "[ \"\$(sysctl -n net.ipv4.ip_forward)\" = \"1\" ]"
    _check "قانون NAT برقرار است"   "iptables -t nat -L POSTROUTING | grep -q MASQUERADE"
  fi

  echo
  if [ "$fail" -eq 0 ]; then
    show_success "همه تست‌ها موفق ($pass از $((pass+fail)))"
    tg_send "✅ <b>تست نصب موفق</b>%0Aنقش: $role%0A${report}سرور: $(hostname)"
  else
    show_error "$fail تست ناموفق بود — لاگ: $LOG_FILE"
    tg_send "⚠️ <b>$fail تست ناموفق</b>%0Aنقش: $role%0A${report}سرور: $(hostname)"
  fi
}

# ─────────────────────────────────────────────
# Health Check
# ─────────────────────────────────────────────
setup_health_check() {
  local role="$1" foreign_wg_ip="${2:-10.8.0.1}"

  cat > /usr/local/bin/wg-health-check <<HCEOF
#!/bin/bash
LOG="/var/log/wg-xui.log"
IFACE="${WG_IFACE}"
WG_CMD="${WG_CMD}"
source /etc/wg-xui/telegram.conf 2>/dev/null || true

log_hc() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [HEALTH] \$1" >> "\$LOG"; }
tg() {
  [ -z "\$TG_TOKEN" ] && return
  curl -s --max-time 10 "https://api.telegram.org/bot\${TG_TOKEN}/sendMessage" \
    -d "chat_id=\${TG_ADMIN_ID}" -d "text=\$1" -d "parse_mode=HTML" -o /dev/null || true
}

if [ -f "\$LOG" ] && [ "\$(stat -c%s "\$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  mv "\${LOG}.2" "\${LOG}.3" 2>/dev/null || true
  mv "\${LOG}.1" "\${LOG}.2" 2>/dev/null || true
  mv "\$LOG"     "\${LOG}.1"; touch "\$LOG"
fi

if ! systemctl is-active --quiet "\${WG_CMD}@\${IFACE}"; then
  log_hc "تونل متوقف بود، ری‌استارت..."
  systemctl restart "\${WG_CMD}@\${IFACE}"
  tg "🔄 <b>تونل ری‌استارت شد (خودکار)</b>%0Aسرور: \$(hostname)"
  log_hc "تونل راه‌اندازی شد"
fi
HCEOF

  if [ "$role" = "iran" ]; then
    cat >> /usr/local/bin/wg-health-check <<HCEOF2

if ! ping -c 2 -W 5 ${foreign_wg_ip} &>/dev/null; then
  log_hc "ping ناموفق، ری‌استارت تونل..."
  systemctl restart "\${WG_CMD}@\${IFACE}"
  sleep 5
  if ping -c 2 -W 5 ${foreign_wg_ip} &>/dev/null; then
    log_hc "تونل بعد از ری‌استارت وصل شد"
    tg "✅ <b>تونل بعد از قطعی وصل شد</b>%0Aسرور: \$(hostname)"
  else
    log_hc "تونل هنوز قطع است"
    tg "🚨 <b>تونل قطع است و وصل نشد!</b>%0Aبررسی دستی لازم است%0Aسرور: \$(hostname)"
  fi
fi

if ! systemctl is-active --quiet x-ui; then
  log_hc "X-UI متوقف بود، ری‌استارت..."
  systemctl restart x-ui
  tg "🔄 <b>X-UI ری‌استارت شد (خودکار)</b>%0Aسرور: \$(hostname)"
fi
HCEOF2
  fi

  chmod +x /usr/local/bin/wg-health-check

  if ! crontab -l 2>/dev/null | grep -q "wg-health-check"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/wg-health-check") | crontab -
    show_success "بررسی سلامت هر ۵ دقیقه تنظیم شد"
  fi

  cat > /etc/logrotate.d/wg-xui <<LREOF
/var/log/wg-xui.log {
    size 5M
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
LREOF
  show_success "مدیریت لاگ تنظیم شد (حداکثر ۱۵ مگابایت)"
}

# ─────────────────────────────────────────────
# منوی مدیریت
# ─────────────────────────────────────────────
manage_tunnel() {
  detect_setup
  show_header "مدیریت تونل"
  echo "   1) وضعیت تونل"
  echo "   2) ری‌استارت تونل"
  echo "   3) توقف تونل"
  echo "   4) شروع تونل"
  echo "   5) نمایش لاگ (آخرین ۵۰ خط)"
  echo "   6) تست اتصال"
  echo "   7) پشتیبان‌گیری فوری X-UI"
  echo "   8) وضعیت ربات تلگرام"
  echo "   9) بازگشت"
  read -p "   گزینه: " mgmt_choice

  case "$mgmt_choice" in
    1)
      show_header "وضعیت تونل"
      systemctl status "${WG_CMD}@${WG_IFACE}" --no-pager || true
      echo
      command -v awg &>/dev/null && awg show "$WG_IFACE" 2>/dev/null || wg show "$WG_IFACE" 2>/dev/null || true
      ;;
    2)
      systemctl restart "${WG_CMD}@${WG_IFACE}"
      show_success "تونل ری‌استارت شد"
      tg_send "🔄 <b>تونل ری‌استارت شد (دستی)</b>%0Aسرور: $(hostname)"
      ;;
    3)
      systemctl stop "${WG_CMD}@${WG_IFACE}"
      show_success "تونل متوقف شد"
      tg_send "⏹ <b>تونل متوقف شد (دستی)</b>%0Aسرور: $(hostname)"
      ;;
    4)
      systemctl start "${WG_CMD}@${WG_IFACE}"
      show_success "تونل شروع شد"
      tg_send "▶️ <b>تونل شروع شد (دستی)</b>%0Aسرور: $(hostname)"
      ;;
    5)
      show_header "آخرین ۵۰ خط لاگ"
      tail -n 50 "$LOG_FILE" 2>/dev/null || echo "   لاگ خالی است"
      ;;
    6)
      read -p "   IP داخلی سرور خارجی (پیشفرض: 10.8.0.1): " fg_ip
      run_post_install_test "iran" "${fg_ip:-10.8.0.1}"
      ;;
    7)
      show_info "در حال ارسال بکاپ به تلگرام..."
      /usr/local/bin/wg-xui-backup 2>/dev/null && show_success "بکاپ ارسال شد" || show_error "بکاپ ناموفق — آیا تلگرام تنظیم شده؟"
      ;;
    8)
      systemctl status wg-tgbot --no-pager 2>/dev/null || echo "   ربات نصب نشده است"
      ;;
    9) return ;;
    *) show_error "گزینه نامعتبر" ;;
  esac
}

# ─────────────────────────────────────────────
# نصب سرور خارجی
# ─────────────────────────────────────────────
install_foreign() {
  show_header "نصب سرور خارجی"

  echo -e "
   ${CYAN}این مرحله روی سرور خارجی (مثلاً آلمان یا هلند) اجرا می‌شود.${NC}
   ابتدا باید این سرور نصب شود، سپس سرور ایران.
"

  # ─── تلگرام ───
  setup_telegram

  # ─── نصب AmneziaWG ───
  show_step "نصب پکیج‌های مورد نیاز"
  install_amneziawg
  apt install -y curl qrencode ufw

  # ─── تولید کلید ───
  show_step "تولید کلیدهای رمزنگاری"
  umask 077
  mkdir -p /etc/amnezia/amneziawg

  if command -v awg &>/dev/null; then
    awg genkey | tee /etc/amnezia/amneziawg/private.key | awg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="awg-quick"; WG_CONF_DIR="/etc/amnezia/amneziawg"; WG_IFACE="awg0"
  else
    apt install -y wireguard
    wg genkey | tee /etc/amnezia/amneziawg/private.key | wg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="wg-quick"; WG_CONF_DIR="/etc/wireguard"; WG_IFACE="wg0"
  fi

  PRIVATE_KEY=$(cat /etc/amnezia/amneziawg/private.key)
  PUBLIC_KEY=$(cat /etc/amnezia/amneziawg/public.key)

  # ─── اطلاعات شبکه ───
  show_step "تنظیمات شبکه تونل"

  show_note "IP تونل یک آدرس خصوصی فرضی است (مثل ۱۰.۸.۰.۱) که فقط داخل تونل استفاده می‌شود."
  show_note "این IP هیچ ربطی به IP عمومی سرور ندارد. مقدار پیشنهادی را قبول کنید."
  show_ask "IP داخلی تونل برای این سرور (پیشنهاد: 10.8.0.1):"
  read -p "   > " WG_IP
  WG_IP=${WG_IP:-10.8.0.1}

  show_note "پورتی که سرور ایران از طریق آن به اینجا وصل می‌شود."
  show_note "این پورت باید در فایروال سرور خارجی باز باشد (UDP). پیشفرض کافی است."
  show_ask "پورت تونل (پیشفرض: 51820):"
  read -p "   > " WG_PORT
  WG_PORT=${WG_PORT:-51820}

  WAN_IF=$(ip route show default | awk '/default/ {print $5; exit}')

  mkdir -p "$WG_CONF_DIR"
  cat > "$WG_CONF_DIR/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $WG_IP/24
ListenPort = $WG_PORT
SaveConfig = false

PostUp   = iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE; iptables -A FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -A FORWARD -o ${WG_IFACE} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE; iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_IFACE} -j ACCEPT
EOF

  if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  sysctl -p

  systemctl enable --now "${WG_CMD}@${WG_IFACE}"
  setup_firewall "$WG_PORT/udp"

  setup_health_check "foreign"
  install_telegram_bot

  echo "$PUBLIC_KEY" > /root/foreign_pubkey.txt
  run_post_install_test "foreign"

  # ─── نمایش نتیجه ───
  show_header "نصب سرور خارجی تکمیل شد"

  echo -e "
   ${GREEN}کلید عمومی این سرور (برای سرور ایران لازم است):${NC}
   ${YELLOW}$PUBLIC_KEY${NC}

   (در فایل /root/foreign_pubkey.txt هم ذخیره شد)
"
  echo "   QR کد کلید عمومی:"
  qrencode -t ansiutf8 "$PUBLIC_KEY"

  echo -e "
   ${CYAN}═══════════════════ مراحل بعدی ═══════════════════${NC}

   ${GREEN}مرحله ۱:${NC} اسکریپت را روی سرور ایران اجرا کنید (گزینه ۲)
            اطلاعاتی که باید با خود داشته باشید:
            • IP عمومی این سرور خارجی: ${YELLOW}$(curl -s --max-time 5 ifconfig.me || echo نامشخص)${NC}
            • پورت تونل: ${YELLOW}$WG_PORT${NC}
            • کلید عمومی بالا

   ${GREEN}مرحله ۲:${NC} بعد از نصب سرور ایران، کلید عمومی آن را بگیرید
            و روی همین سرور دستور زیر را اجرا کنید:

   ${YELLOW}${WG_CMD%-quick} set $WG_IFACE peer <کلید-عمومی-سرور-ایران> allowed-ips 10.8.0.2/32${NC}
   ${YELLOW}${WG_CMD%-quick}-quick save $WG_IFACE${NC}

   ${CYAN}═══════════════════════════════════════════════════${NC}
"
  tg_send "✅ <b>سرور خارجی نصب شد</b>%0Aسرور: $(hostname)%0AIP: $(curl -s --max-time 5 ifconfig.me || echo نامشخص)"
  log "INSTALL" "foreign server installed"
}

# ─────────────────────────────────────────────
# نصب سرور ایران
# ─────────────────────────────────────────────
install_iran() {
  show_header "نصب سرور ایران"

  echo -e "
   ${CYAN}این مرحله روی سرور ایران اجرا می‌شود.${NC}
   ${RED}قبل از شروع مطمئن شوید سرور خارجی را قبلاً نصب کرده‌اید.${NC}
   اطلاعات سرور خارجی را آماده داشته باشید.
"

  setup_telegram

  show_step "نصب پکیج‌های مورد نیاز"
  install_amneziawg
  apt install -y curl

  # ─── اطلاعات تونل ───
  show_step "اطلاعات اتصال به سرور خارجی"

  show_note "آدرس IP خصوصی تونل برای این سرور ایران (باید با سرور خارجی در یک رنج باشد)."
  show_note "اگر سرور خارجی 10.8.0.1 گرفته، اینجا 10.8.0.2 وارد کنید."
  show_ask "IP داخلی تونل برای این سرور ایران (پیشنهاد: 10.8.0.2):"
  read -p "   > " WG_IP
  WG_IP=${WG_IP:-10.8.0.2}

  show_note "IP عمومی یعنی آدرسی که در اینترنت به سرور خارجی وصل می‌شوید (نه IP تونل)."
  show_note "مثال: 185.92.12.34"
  show_ask "IP عمومی سرور خارجی (آدرس واقعی سرور خارجی در اینترنت):"
  read -p "   > " FOREIGN_IP

  show_note "همان پورتی که موقع نصب سرور خارجی وارد کردید."
  show_ask "پورت تونل سرور خارجی (پیشفرض: 51820):"
  read -p "   > " WG_PORT
  WG_PORT=${WG_PORT:-51820}

  show_note "این کلید را هنگام نصب سرور خارجی به شما نشان داد."
  show_note "در سرور خارجی هم در /root/foreign_pubkey.txt ذخیره شده."
  show_ask "کلید عمومی سرور خارجی (رشته بلند حروف و اعداد):"
  read -p "   > " FOREIGN_PUBLIC_KEY

  show_note "IP خصوصی تونل سرور خارجی — همان چیزی که موقع نصبش وارد کردید (معمولاً 10.8.0.1)."
  show_ask "IP داخلی تونل سرور خارجی (پیشفرض: 10.8.0.1):"
  read -p "   > " FOREIGN_WG_IP
  FOREIGN_WG_IP=${FOREIGN_WG_IP:-10.8.0.1}

  # ─── تولید کلید ───
  show_step "تولید کلیدهای رمزنگاری"
  umask 077
  mkdir -p /etc/amnezia/amneziawg

  if command -v awg &>/dev/null; then
    awg genkey | tee /etc/amnezia/amneziawg/private.key | awg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="awg-quick"; WG_CONF_DIR="/etc/amnezia/amneziawg"; WG_IFACE="awg0"
  else
    apt install -y wireguard
    wg genkey | tee /etc/amnezia/amneziawg/private.key | wg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="wg-quick"; WG_CONF_DIR="/etc/wireguard"; WG_IFACE="wg0"
  fi

  PRIVATE_KEY=$(cat /etc/amnezia/amneziawg/private.key)
  PUBLIC_KEY=$(cat /etc/amnezia/amneziawg/public.key)

  DEFAULT_GW=$(ip route show default | awk '/default/ {print $3; exit}')
  DEFAULT_IF=$(ip route show default | awk '/default/ {print $5; exit}')

  mkdir -p "$WG_CONF_DIR"
  cat > "$WG_CONF_DIR/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $WG_IP/24
DNS = 8.8.8.8, 1.1.1.1

PostUp   = ip route add $FOREIGN_IP via $DEFAULT_GW dev $DEFAULT_IF 2>/dev/null || true
PostDown = ip route del $FOREIGN_IP via $DEFAULT_GW dev $DEFAULT_IF 2>/dev/null || true

[Peer]
PublicKey = $FOREIGN_PUBLIC_KEY
Endpoint = $FOREIGN_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  systemctl enable --now "${WG_CMD}@${WG_IFACE}"
  setup_health_check "iran" "$FOREIGN_WG_IP"

  # ─── X-UI ───
  show_step "نصب پنل 3X-UI"
  show_note "پنل مدیریت کاربران VPN نصب می‌شود. این فرآیند چند دقیقه طول می‌کشد."
  bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y" || {
    show_error "نصب 3X-UI ناموفق — برای نصب دستی:"
    echo "   bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
  }

  setup_firewall "80/tcp" "443/tcp" "54321/tcp"

  install_telegram_bot
  setup_xui_backup

  echo "$PUBLIC_KEY" > /root/iran_pubkey.txt
  run_post_install_test "iran" "$FOREIGN_WG_IP"

  # تست تلگرام بعد از وصل شدن تونل
  tg_load
  if [ -n "$TG_TOKEN" ]; then
    show_info "تست ارسال پیام به تلگرام از طریق تونل..."
    sleep 2
    local tg_result
    tg_result=$(curl -s --max-time 10 \
      "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d "chat_id=${TG_ADMIN_ID}" \
      -d "text=✅ <b>سرور ایران نصب شد و تونل وصل است</b>" \
      -d "parse_mode=HTML" 2>/dev/null || echo "fail")
    if echo "$tg_result" | grep -q '"ok":true'; then
      show_success "پیام تست در تلگرام ارسال شد"
    else
      show_info "تلگرام هنوز در دسترس نیست — بعد از تکمیل مرحله آخر وصل می‌شود"
    fi
  fi

  # ─── نمایش نتیجه ───
  PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || echo "نامشخص")
  show_header "نصب سرور ایران تکمیل شد"

  echo -e "
   ${GREEN}پنل مدیریت 3X-UI:${NC}
   آدرس:     ${YELLOW}http://${PUBLIC_IP}:54321${NC}
   کاربری:   ${YELLOW}admin${NC}
   رمز:       ${YELLOW}admin${NC}
   ${RED}⚠️  بلافاصله رمز عبور را از پنل تغییر دهید!${NC}

   ${GREEN}کلید عمومی این سرور ایران (برای مرحله آخر لازم است):${NC}
   ${YELLOW}$PUBLIC_KEY${NC}

   (در فایل /root/iran_pubkey.txt هم ذخیره شد)

   ${CYAN}═══════════════════ مرحله آخر ═══════════════════${NC}

   ${RED}مهم:${NC} روی سرور خارجی این دو دستور را اجرا کنید
        تا ارتباط دو طرفه تونل کامل شود:

   ${YELLOW}${WG_CMD%-quick} set $WG_IFACE peer $PUBLIC_KEY allowed-ips $WG_IP/32${NC}
   ${YELLOW}${WG_CMD%-quick}-quick save $WG_IFACE${NC}

   ${CYAN}═══════════════════════════════════════════════════${NC}
"
  tg_send "✅ <b>سرور ایران نصب شد</b>%0Aسرور: $(hostname)%0AIP: ${PUBLIC_IP}%0Aپنل: http://${PUBLIC_IP}:54321%0A%0A⚠️ رمز عبور پنل را تغییر دهید!"
  log "INSTALL" "iran server installed"
}

# ─────────────────────────────────────────────
# منوی اصلی
# ─────────────────────────────────────────────
show_header "مدیریت تونل AmneziaWG + 3X-UI"
echo -e "
   ${YELLOW}ترتیب نصب:${NC}
   ۱. ابتدا روی سرور خارجی (گزینه ۱) نصب کنید
   ۲. سپس روی سرور ایران (گزینه ۲) نصب کنید
   ۳. در آخر یک دستور روی سرور خارجی اجرا کنید (توضیح داده می‌شود)
"
echo "   1) نصب روی سرور خارجی"
echo "   2) نصب روی سرور ایران"
echo "   3) مدیریت تونل"
echo "   4) خروج"
read -p "   گزینه مورد نظر (1-4): " choice

case "$choice" in
  1) install_foreign ;;
  2) install_iran ;;
  3) manage_tunnel ;;
  4) exit 0 ;;
  *) show_error "گزینه نامعتبر!"; exit 1 ;;
esac
