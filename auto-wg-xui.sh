#!/bin/bash
set -e

# ─────────────────────────────────────────────
# رنگ‌ها
# ─────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
LINE="================================================================"

show_error()   { echo -e "${RED}❌ $1${NC}";    log "ERROR" "$1"; }
show_success() { echo -e "${GREEN}✅ $1${NC}";  log "OK"    "$1"; }
show_info()    { echo -e "${YELLOW}🔹 $1${NC}"; log "INFO"  "$1"; }
show_header()  { echo -e "${CYAN}$LINE\n$1\n$LINE${NC}"; }

# ─────────────────────────────────────────────
# لاگ با چرخش خودکار (max 5MB، 3 فایل)
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# بررسی دسترسی root
# ─────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ لطفاً این اسکریپت را با دسترسی root اجرا کنید${NC}"
  exit 1
fi

# ─────────────────────────────────────────────
# تشخیص ابزار و interface فعال
# ─────────────────────────────────────────────
detect_setup() {
  if command -v awg-quick &>/dev/null; then
    WG_CMD="awg-quick"; WG_IFACE="awg0"; WG_CONF_DIR="/etc/amnezia/amneziawg"
  else
    WG_CMD="wg-quick";  WG_IFACE="wg0";  WG_CONF_DIR="/etc/wireguard"
  fi
}

# ─────────────────────────────────────────────
# توابع تلگرام
# ─────────────────────────────────────────────
tg_load() {
  [ -f "$TG_CONFIG" ] && source "$TG_CONFIG" || true
}

tg_send() {
  tg_load
  [ -z "$TG_TOKEN" ] || [ -z "$TG_ADMIN_ID" ] && return 0
  local text="$1"
  curl -s --max-time 10 \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" \
    -d "text=${text}" \
    -d "parse_mode=HTML" \
    -o /dev/null || true
}

tg_send_file() {
  tg_load
  [ -z "$TG_TOKEN" ] || [ -z "$TG_ADMIN_ID" ] && return 0
  local file="$1" caption="$2"
  curl -s --max-time 30 \
    "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
    -F "chat_id=${TG_ADMIN_ID}" \
    -F "document=@${file}" \
    -F "caption=${caption}" \
    -o /dev/null || true
}

# ─────────────────────────────────────────────
# تنظیم توکن تلگرام
# ─────────────────────────────────────────────
setup_telegram() {
  show_header "تنظیم ربات تلگرام"
  echo "برای ساخت ربات به @BotFather در تلگرام مراجعه کنید"
  echo "سپس توکن و Chat ID ادمین را وارد کنید"
  echo "(برای رد کردن Enter بزنید)"
  echo
  read -p "توکن ربات (مثال: 123456:ABC-DEF...): " input_token
  if [ -z "$input_token" ]; then
    show_info "تلگرام رد شد"
    return
  fi
  read -p "Chat ID ادمین (عدد): " input_admin_id
  if [ -z "$input_admin_id" ]; then
    show_info "تلگرام رد شد"
    return
  fi

  # تست توکن
  show_info "در حال بررسی توکن..."
  local result
  result=$(curl -s --max-time 10 "https://api.telegram.org/bot${input_token}/getMe")
  if echo "$result" | grep -q '"ok":true'; then
    mkdir -p /etc/wg-xui
    cat > "$TG_CONFIG" <<EOF
TG_TOKEN="${input_token}"
TG_ADMIN_ID="${input_admin_id}"
EOF
    chmod 600 "$TG_CONFIG"
    show_success "توکن ربات معتبر است"
    tg_send "✅ <b>ربات متصل شد</b>%0Aسرور: $(hostname)%0AIP: $(curl -s --max-time 5 ifconfig.me)"
    show_success "پیام تست به تلگرام ارسال شد"
  else
    show_error "توکن نامعتبر است — تلگرام تنظیم نشد"
  fi
}

# ─────────────────────────────────────────────
# ساخت سرویس ربات تلگرام (Python polling)
# ─────────────────────────────────────────────
install_telegram_bot() {
  tg_load
  [ -z "$TG_TOKEN" ] && return 0

  show_info "نصب ربات تلگرام..."
  apt install -y python3 python3-pip -qq
  pip3 install requests -q

  detect_setup

  cat > /usr/local/bin/wg-tgbot.py <<PYEOF
#!/usr/bin/env python3
import requests, subprocess, os, time, json, shutil
from datetime import datetime

TOKEN    = open("/etc/wg-xui/telegram.conf").read()
TOKEN    = [l.split("=")[1].strip().strip('"') for l in TOKEN.splitlines() if l.startswith("TG_TOKEN")][0]
ADMIN_ID = open("/etc/wg-xui/telegram.conf").read()
ADMIN_ID = int([l.split("=")[1].strip().strip('"') for l in ADMIN_ID.splitlines() if l.startswith("TG_ADMIN_ID")][0])

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
                          files={"document": f},
                          timeout=30)
    except Exception:
        pass

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return (r.stdout + r.stderr).strip() or "✅ اجرا شد"
    except Exception as e:
        return f"❌ خطا: {e}"

def backup_xui():
    if not os.path.exists(XUI_DB):
        return None
    ts  = datetime.now().strftime("%Y%m%d_%H%M%S")
    dst = f"/tmp/x-ui-backup-{ts}.db"
    shutil.copy2(XUI_DB, dst)
    return dst

HELP = """📋 <b>دستورات ربات:</b>

/status — وضعیت تونل
/restart — ری‌استارت تونل
/restart_xui — ری‌استارت X-UI
/start — شروع تونل
/stop — توقف تونل
/log — آخرین ۵۰ خط لاگ
/test — تست اتصال
/backup — پشتیبان‌گیری از X-UI
/help — این راهنما"""

COMMANDS = {
    "/start":       lambda: "👋 ربات فعال است. /help برای راهنما",
    "/help":        lambda: HELP,
    "/status":      lambda: f"📊 <b>وضعیت تونل:</b>\n<pre>{run(f'systemctl status {WG_CMD}@{WG_IFACE} --no-pager -l | head -20')}</pre>",
    "/restart":     lambda: f"🔄 {run(f'systemctl restart {WG_CMD}@{WG_IFACE}')}  تونل ری‌استارت شد",
    "/restart_xui": lambda: f"🔄 {run('systemctl restart x-ui')}  X-UI ری‌استارت شد",
    "/stop":        lambda: f"⏹ {run(f'systemctl stop {WG_CMD}@{WG_IFACE}')}  تونل متوقف شد",
    "/test":        lambda: (
        lambda ping=run("ping -c 3 -W 4 10.8.0.1"),
               inet=run("curl -s --max-time 8 https://1.1.1.1 -o /dev/null -w '%{http_code}'"),
               xui=run("systemctl is-active x-ui"):
        f"🧪 <b>نتیجه تست:</b>\nping سرور خارجی: {'✅' if '0%' in ping else '❌'}\nاینترنت: {'✅' if inet.strip()=='200' else '❌'}\nX-UI: {'✅' if xui.strip()=='active' else '❌'}"
    )(),
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
                         params={"offset": offset, "timeout": 30},
                         timeout=35)
        updates = r.json().get("result", [])
        for u in updates:
            offset = u["update_id"] + 1
            msg    = u.get("message") or u.get("edited_message", {})
            if not msg:
                continue
            cid  = msg["chat"]["id"]
            text = msg.get("text", "").strip()
            if cid != ADMIN_ID:
                send("⛔ دسترسی ندارید", cid)
                continue
            if text == "/log":
                handle_log(cid)
            elif text == "/backup":
                handle_backup(cid)
            elif text in COMMANDS:
                send(COMMANDS[text](), cid)
            else:
                send("❓ دستور نامشخص — /help", cid)
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
  show_success "ربات تلگرام نصب و فعال شد"
}

# ─────────────────────────────────────────────
# پشتیبان‌گیری خودکار از X-UI
# ─────────────────────────────────────────────
setup_xui_backup() {
  tg_load
  [ -z "$TG_TOKEN" ] && return 0

  cat > /usr/local/bin/wg-xui-backup <<'BKEOF'
#!/bin/bash
source /etc/wg-xui/telegram.conf 2>/dev/null || exit 0
XUI_DB="/etc/x-ui/x-ui.db"
LOG="/var/log/wg-xui.log"
[ -f "$XUI_DB" ] || exit 0

TS=$(date '+%Y%m%d_%H%M%S')
DST="/tmp/x-ui-backup-${TS}.db"
cp "$XUI_DB" "$DST"

curl -s --max-time 30 \
  "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
  -F "chat_id=${TG_ADMIN_ID}" \
  -F "document=@${DST}" \
  -F "caption=💾 بکاپ خودکار X-UI — $(date '+%Y-%m-%d %H:%M')" \
  -o /dev/null

rm -f "$DST"
echo "$(date '+%Y-%m-%d %H:%M:%S') [BACKUP] x-ui backup sent to telegram" >> "$LOG"
BKEOF

  chmod +x /usr/local/bin/wg-xui-backup

  # هر روز ساعت ۳ شب
  if ! crontab -l 2>/dev/null | grep -q "wg-xui-backup"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/wg-xui-backup") | crontab -
    show_success "پشتیبان‌گیری خودکار هر روز ساعت ۳ صبح تنظیم شد"
  fi
}

# ─────────────────────────────────────────────
# نصب AmneziaWG
# ─────────────────────────────────────────────
install_amneziawg() {
  show_info "نصب AmneziaWG (ضد فیلتر)..."
  apt update -qq
  if ! command -v awg-quick &>/dev/null; then
    apt install -y software-properties-common
    add-apt-repository -y ppa:amnezia/ppa 2>/dev/null || true
    apt update -qq
    apt install -y amneziawg amneziawg-tools || {
      show_info "PPA در دسترس نیست، fallback به WireGuard..."
      apt install -y wireguard-dkms wireguard-tools linux-headers-$(uname -r) git make gcc
    }
  fi
}

# ─────────────────────────────────────────────
# تست کامل اتصال
# ─────────────────────────────────────────────
run_post_install_test() {
  local role="$1"
  local foreign_wg_ip="$2"
  local report=""

  show_header "تست خودکار بعد از نصب"
  local pass=0 fail=0

  _check() {
    local label="$1" cmd="$2"
    if eval "$cmd" &>/dev/null; then
      echo -e "  ${GREEN}✅ $label${NC}"
      log "TEST-OK" "$label"
      report+="✅ $label%0A"
      ((pass++)) || true
    else
      echo -e "  ${RED}❌ $label${NC}"
      log "TEST-FAIL" "$label"
      report+="❌ $label%0A"
      ((fail++)) || true
    fi
  }

  detect_setup
  _check "سرویس تونل فعال است"   "systemctl is-active --quiet ${WG_CMD}@${WG_IFACE}"
  _check "interface تونل بالا است" "ip link show ${WG_IFACE}"

  if [ "$role" = "iran" ]; then
    _check "ping به سرور خارجی (${foreign_wg_ip})" "ping -c 2 -W 4 ${foreign_wg_ip}"
    _check "دسترسی به اینترنت از طریق تونل"         "curl -s --max-time 8 https://1.1.1.1 -o /dev/null"
    _check "DNS کار می‌کند"                          "nslookup google.com 8.8.8.8"
    _check "سرویس 3X-UI فعال است"                   "systemctl is-active --quiet x-ui"
  fi

  if [ "$role" = "foreign" ]; then
    _check "IP Forwarding فعال است" "[ \"\$(sysctl -n net.ipv4.ip_forward)\" = \"1\" ]"
    _check "قانون NAT برقرار است"   "iptables -t nat -L POSTROUTING | grep -q MASQUERADE"
  fi

  echo
  if [ "$fail" -eq 0 ]; then
    show_success "همه تست‌ها موفق ($pass/$((pass+fail)))"
    tg_send "✅ <b>تست نصب موفق — $role</b>%0A${report}سرور: $(hostname)"
  else
    show_error "$fail تست ناموفق — لاگ: $LOG_FILE"
    tg_send "⚠️ <b>تست نصب: $fail ناموفق — $role</b>%0A${report}سرور: $(hostname)"
  fi
}

# ─────────────────────────────────────────────
# Health Check
# ─────────────────────────────────────────────
setup_health_check() {
  local role="$1"
  local foreign_wg_ip="${2:-10.8.0.1}"

  cat > /usr/local/bin/wg-health-check <<HCEOF
#!/bin/bash
LOG="/var/log/wg-xui.log"
IFACE="${WG_IFACE}"
WG_CMD="${WG_CMD}"
source /etc/wg-xui/telegram.conf 2>/dev/null || true

log_hc() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [HEALTH] \$1" >> "\$LOG"; }
tg()     {
  [ -z "\$TG_TOKEN" ] && return
  curl -s --max-time 10 "https://api.telegram.org/bot\${TG_TOKEN}/sendMessage" \
    -d "chat_id=\${TG_ADMIN_ID}" -d "text=\$1" -d "parse_mode=HTML" -o /dev/null || true
}

# چرخش لاگ
if [ -f "\$LOG" ] && [ "\$(stat -c%s "\$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  mv "\${LOG}.2" "\${LOG}.3" 2>/dev/null || true
  mv "\${LOG}.1" "\${LOG}.2" 2>/dev/null || true
  mv "\$LOG"     "\${LOG}.1"
  touch "\$LOG"
fi

if ! systemctl is-active --quiet "\${WG_CMD}@\${IFACE}"; then
  log_hc "تونل متوقف بود، ری‌استارت..."
  systemctl restart "\${WG_CMD}@\${IFACE}"
  tg "🔄 <b>تونل ری‌استارت شد</b>%0Aسرور: \$(hostname)"
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
    tg "🚨 <b>تونل قطع است و وصل نشد!</b>%0Aسرور: \$(hostname)%0Aبررسی دستی لازم است"
  fi
fi

if ! systemctl is-active --quiet x-ui; then
  log_hc "X-UI متوقف بود، ری‌استارت..."
  systemctl restart x-ui
  tg "🔄 <b>X-UI ری‌استارت شد</b>%0Aسرور: \$(hostname)"
fi
HCEOF2
  fi

  chmod +x /usr/local/bin/wg-health-check

  if ! crontab -l 2>/dev/null | grep -q "wg-health-check"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/wg-health-check") | crontab -
    show_success "Health check هر ۵ دقیقه اجرا می‌شود"
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
  show_success "logrotate تنظیم شد (max 15MB)"
}

# ─────────────────────────────────────────────
# منوی مدیریت
# ─────────────────────────────────────────────
manage_tunnel() {
  detect_setup
  show_header "مدیریت تونل"
  echo "1) وضعیت تونل"
  echo "2) ری‌استارت تونل"
  echo "3) توقف تونل"
  echo "4) شروع تونل"
  echo "5) نمایش لاگ (آخرین ۵۰ خط)"
  echo "6) تست اتصال"
  echo "7) پشتیبان‌گیری فوری X-UI"
  echo "8) وضعیت ربات تلگرام"
  echo "9) بازگشت"
  read -p "گزینه: " mgmt_choice

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
      log "MANAGE" "tunnel restarted"
      tg_send "🔄 <b>تونل ری‌استارت شد</b> (دستی)%0Aسرور: $(hostname)"
      ;;
    3)
      systemctl stop "${WG_CMD}@${WG_IFACE}"
      show_success "تونل متوقف شد"
      log "MANAGE" "tunnel stopped"
      tg_send "⏹ <b>تونل متوقف شد</b> (دستی)%0Aسرور: $(hostname)"
      ;;
    4)
      systemctl start "${WG_CMD}@${WG_IFACE}"
      show_success "تونل شروع شد"
      log "MANAGE" "tunnel started"
      tg_send "▶️ <b>تونل شروع شد</b> (دستی)%0Aسرور: $(hostname)"
      ;;
    5)
      show_header "آخرین ۵۰ خط لاگ"
      tail -n 50 "$LOG_FILE" 2>/dev/null || echo "لاگ خالی است"
      ;;
    6)
      read -p "IP داخلی سرور خارجی (پیشفرض: 10.8.0.1): " fg_ip
      run_post_install_test "iran" "${fg_ip:-10.8.0.1}"
      ;;
    7)
      show_info "در حال ارسال بکاپ..."
      /usr/local/bin/wg-xui-backup 2>/dev/null && show_success "بکاپ ارسال شد" || show_error "بکاپ ناموفق بود"
      ;;
    8)
      systemctl status wg-tgbot --no-pager || echo "ربات نصب نشده"
      ;;
    9) return ;;
    *) show_error "گزینه نامعتبر" ;;
  esac
}

# ─────────────────────────────────────────────
# نصب سرور خارجی
# ─────────────────────────────────────────────
install_foreign() {
  show_header "در حال راه‌اندازی سرور خارجی"

  setup_telegram

  install_amneziawg
  apt install -y curl qrencode iptables-persistent

  show_info "تولید کلیدهای رمزنگاری..."
  umask 077
  mkdir -p /etc/amnezia/amneziawg

  if command -v awg &>/dev/null; then
    awg genkey | tee /etc/amnezia/amneziawg/private.key | awg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="awg-quick"; WG_CONF_DIR="/etc/amnezia/amneziawg"; WG_IFACE="awg0"
  else
    show_info "AmneziaWG نصب نشد، fallback به WireGuard..."
    apt install -y wireguard
    wg genkey | tee /etc/amnezia/amneziawg/private.key | wg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="wg-quick"; WG_CONF_DIR="/etc/wireguard"; WG_IFACE="wg0"
  fi

  PRIVATE_KEY=$(cat /etc/amnezia/amneziawg/private.key)
  PUBLIC_KEY=$(cat /etc/amnezia/amneziawg/public.key)

  read -p "IP داخلی سرور خارجی (پیشنهاد: 10.8.0.1): " WG_IP
  WG_IP=${WG_IP:-10.8.0.1}
  read -p "پورت تونل (پیشفرض: 51820): " WG_PORT
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
  ufw allow "$WG_PORT/udp"
  ufw allow ssh
  ufw --force enable

  setup_health_check "foreign"
  install_telegram_bot

  echo "$PUBLIC_KEY" > /root/foreign_pubkey.txt
  run_post_install_test "foreign"

  show_success "نصب سرور خارجی تکمیل شد!"
  show_info "کلید عمومی سرور خارجی: $PUBLIC_KEY"
  echo
  qrencode -t ansiutf8 "$PUBLIC_KEY"
  echo
  show_info "مرحله بعد:"
  echo "  ۱. اسکریپت را روی سرور ایران اجرا کنید (گزینه ۲)"
  echo "  ۲. کلید عمومی سرور ایران را بگیرید"
  echo "  ۳. روی همین سرور خارجی دستور زیر را اجرا کنید:"
  echo "  ${WG_CMD%-quick} set $WG_IFACE peer <PUBLIC_KEY_IRAN> allowed-ips 10.8.0.2/32"
  echo "  ${WG_CMD%-quick}-quick save $WG_IFACE"
  echo
  tg_send "✅ <b>سرور خارجی نصب شد</b>%0Aسرور: $(hostname)%0AIP: $(curl -s --max-time 5 ifconfig.me)"
  log "INSTALL" "foreign server installed"
}

# ─────────────────────────────────────────────
# نصب سرور ایران
# ─────────────────────────────────────────────
install_iran() {
  show_header "در حال راه‌اندازی سرور ایران"

  setup_telegram

  install_amneziawg
  apt install -y curl

  read -p "IP داخلی سرور ایران (پیشنهاد: 10.8.0.2): " WG_IP
  WG_IP=${WG_IP:-10.8.0.2}
  read -p "IP عمومی سرور خارجی: " FOREIGN_IP
  read -p "پورت تونل سرور خارجی (پیشفرض: 51820): " WG_PORT
  WG_PORT=${WG_PORT:-51820}
  read -p "کلید عمومی سرور خارجی: " FOREIGN_PUBLIC_KEY
  read -p "IP داخلی سرور خارجی (پیشفرض: 10.8.0.1): " FOREIGN_WG_IP
  FOREIGN_WG_IP=${FOREIGN_WG_IP:-10.8.0.1}

  show_info "تولید کلیدهای رمزنگاری..."
  umask 077
  mkdir -p /etc/amnezia/amneziawg

  if command -v awg &>/dev/null; then
    awg genkey | tee /etc/amnezia/amneziawg/private.key | awg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="awg-quick"; WG_CONF_DIR="/etc/amnezia/amneziawg"; WG_IFACE="awg0"
  else
    show_info "AmneziaWG نصب نشد، fallback به WireGuard..."
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

  show_info "در حال نصب پنل 3X-UI..."
  bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y" || {
    show_error "نصب 3X-UI ناموفق — دستی نصب کنید:"
    echo "  bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
  }

  ufw allow ssh
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 54321/tcp
  ufw --force enable

  install_telegram_bot
  setup_xui_backup

  echo "$PUBLIC_KEY" > /root/iran_pubkey.txt
  run_post_install_test "iran" "$FOREIGN_WG_IP"

  show_success "نصب سرور ایران تکمیل شد!"
  PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || echo "نامشخص")
  show_info "پنل مدیریت 3X-UI: http://${PUBLIC_IP}:54321"
  show_info "نام کاربری: admin  |  رمز عبور: admin"
  echo -e "  ${RED}⚠️  رمز عبور را بلافاصله تغییر دهید!${NC}"
  echo
  show_info "کلید عمومی سرور ایران:"
  echo "  $PUBLIC_KEY"
  echo
  show_info "مرحله آخر — روی سرور خارجی اجرا کنید:"
  echo "  ${WG_CMD%-quick} set $WG_IFACE peer $PUBLIC_KEY allowed-ips $WG_IP/32"
  echo "  ${WG_CMD%-quick}-quick save $WG_IFACE"
  echo
  tg_send "✅ <b>سرور ایران نصب شد</b>%0Aسرور: $(hostname)%0AIP: ${PUBLIC_IP}%0Aپنل: http://${PUBLIC_IP}:54321"
  log "INSTALL" "iran server installed"
}

# ─────────────────────────────────────────────
# منوی اصلی
# ─────────────────────────────────────────────
show_header "مدیریت تونل AmneziaWG + 3X-UI"
echo "1) نصب روی سرور خارجی"
echo "2) نصب روی سرور ایران"
echo "3) مدیریت تونل"
echo "4) خروج"
read -p "لطفاً گزینه مورد نظر را انتخاب کنید (1-4): " choice

case "$choice" in
  1) install_foreign ;;
  2) install_iran ;;
  3) manage_tunnel ;;
  4) exit 0 ;;
  *) show_error "گزینه نامعتبر!"; exit 1 ;;
esac
