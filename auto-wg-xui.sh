#!/bin/bash
set -e

# ─────────────────────────────────────────────
# رنگ‌ها
# ─────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
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

log() {
  local level="$1"
  local msg="$2"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
  # چرخش لاگ: اگر فایل بزرگتر از 5MB شد rotate می‌کند
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
    WG_CMD="awg-quick"
    WG_IFACE="awg0"
    WG_CONF_DIR="/etc/amnezia/amneziawg"
  else
    WG_CMD="wg-quick"
    WG_IFACE="wg0"
    WG_CONF_DIR="/etc/wireguard"
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
# تست کامل اتصال بعد از نصب
# ─────────────────────────────────────────────
run_post_install_test() {
  local role="$1"        # iran | foreign
  local foreign_wg_ip="$2"   # برای سرور ایران: IP داخلی سرور خارجی

  show_header "تست خودکار بعد از نصب"
  local pass=0
  local fail=0

  _check() {
    local label="$1"
    local cmd="$2"
    if eval "$cmd" &>/dev/null; then
      echo -e "  ${GREEN}✅ $label${NC}"
      log "TEST-OK" "$label"
      ((pass++)) || true
    else
      echo -e "  ${RED}❌ $label${NC}"
      log "TEST-FAIL" "$label"
      ((fail++)) || true
    fi
  }

  detect_setup

  _check "سرویس تونل فعال است" "systemctl is-active --quiet ${WG_CMD}@${WG_IFACE}"
  _check "interface تونل بالا است" "ip link show ${WG_IFACE}"

  if [ "$role" = "iran" ]; then
    _check "ping به سرور خارجی (${foreign_wg_ip})" "ping -c 2 -W 4 ${foreign_wg_ip}"
    _check "دسترسی به اینترنت از طریق تونل" "curl -s --max-time 8 https://1.1.1.1 -o /dev/null"
    _check "DNS کار می‌کند" "nslookup google.com 8.8.8.8"
    _check "سرویس 3X-UI فعال است" "systemctl is-active --quiet x-ui"
  fi

  if [ "$role" = "foreign" ]; then
    _check "IP Forwarding فعال است" "[ \"\$(sysctl -n net.ipv4.ip_forward)\" = \"1\" ]"
    _check "قانون NAT برقرار است" "iptables -t nat -L POSTROUTING | grep -q MASQUERADE"
  fi

  echo
  if [ "$fail" -eq 0 ]; then
    show_success "همه تست‌ها موفق بودند ($pass/$((pass+fail)))"
  else
    show_error "$fail تست ناموفق بود — لاگ را ببینید: $LOG_FILE"
  fi
}

# ─────────────────────────────────────────────
# Health Check (برای cron)
# ─────────────────────────────────────────────
setup_health_check() {
  local role="$1"
  local foreign_wg_ip="${2:-10.8.0.1}"

  cat > /usr/local/bin/wg-health-check <<HCEOF
#!/bin/bash
LOG="/var/log/wg-xui.log"
IFACE="${WG_IFACE}"
WG_CMD="${WG_CMD}"

log_hc() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [HEALTH] \$1" >> "\$LOG"; }

# چرخش لاگ
if [ -f "\$LOG" ] && [ "\$(stat -c%s "\$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  mv "\${LOG}.2" "\${LOG}.3" 2>/dev/null || true
  mv "\${LOG}.1" "\${LOG}.2" 2>/dev/null || true
  mv "\$LOG"     "\${LOG}.1"
  touch "\$LOG"
fi

# بررسی سرویس
if ! systemctl is-active --quiet "\${WG_CMD}@\${IFACE}"; then
  log_hc "سرویس تونل متوقف بود، در حال راه‌اندازی مجدد..."
  systemctl restart "\${WG_CMD}@\${IFACE}"
  log_hc "سرویس تونل راه‌اندازی شد"
fi

HCEOF

  # برای سرور ایران: تست دسترسی به اینترنت هم اضافه می‌شود
  if [ "$role" = "iran" ]; then
    cat >> /usr/local/bin/wg-health-check <<HCEOF2

# بررسی اتصال اینترنت از طریق تونل
if ! ping -c 2 -W 5 ${foreign_wg_ip} &>/dev/null; then
  log_hc "ping به سرور خارجی ناموفق بود، ری‌استارت تونل..."
  systemctl restart "\${WG_CMD}@\${IFACE}"
  sleep 5
  if ping -c 2 -W 5 ${foreign_wg_ip} &>/dev/null; then
    log_hc "تونل بعد از ری‌استارت وصل شد"
  else
    log_hc "تونل هنوز قطع است — بررسی دستی لازم است"
  fi
fi

# بررسی X-UI
if ! systemctl is-active --quiet x-ui; then
  log_hc "سرویس X-UI متوقف بود، در حال راه‌اندازی مجدد..."
  systemctl restart x-ui
  log_hc "X-UI راه‌اندازی شد"
fi
HCEOF2
  fi

  chmod +x /usr/local/bin/wg-health-check

  # cron هر ۵ دقیقه یک بار
  if ! crontab -l 2>/dev/null | grep -q "wg-health-check"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/wg-health-check") | crontab -
    show_success "Health check هر ۵ دقیقه اجرا می‌شود"
  fi

  # logrotate برای جلوگیری از پر شدن دیسک
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
  show_success "logrotate تنظیم شد (max 5MB × 3 فایل = 15MB)"
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
  echo "7) بازگشت به منوی اصلی"
  read -p "گزینه: " mgmt_choice

  case "$mgmt_choice" in
    1)
      show_header "وضعیت تونل"
      systemctl status "${WG_CMD}@${WG_IFACE}" --no-pager || true
      echo
      if command -v awg &>/dev/null; then
        awg show "$WG_IFACE" 2>/dev/null || true
      else
        wg show "$WG_IFACE" 2>/dev/null || true
      fi
      ;;
    2)
      show_info "ری‌استارت تونل..."
      systemctl restart "${WG_CMD}@${WG_IFACE}"
      show_success "تونل ری‌استارت شد"
      log "MANAGE" "tunnel restarted by user"
      ;;
    3)
      show_info "توقف تونل..."
      systemctl stop "${WG_CMD}@${WG_IFACE}"
      show_success "تونل متوقف شد"
      log "MANAGE" "tunnel stopped by user"
      ;;
    4)
      show_info "شروع تونل..."
      systemctl start "${WG_CMD}@${WG_IFACE}"
      show_success "تونل شروع شد"
      log "MANAGE" "tunnel started by user"
      ;;
    5)
      show_header "آخرین ۵۰ خط لاگ"
      tail -n 50 "$LOG_FILE" 2>/dev/null || echo "فایل لاگ خالی است"
      ;;
    6)
      read -p "IP داخلی سرور خارجی (پیشفرض: 10.8.0.1): " fg_ip
      fg_ip=${fg_ip:-10.8.0.1}
      run_post_install_test "iran" "$fg_ip"
      ;;
    7) return ;;
    *) show_error "گزینه نامعتبر" ;;
  esac
}

# ─────────────────────────────────────────────
# نصب سرور خارجی
# ─────────────────────────────────────────────
install_foreign() {
  show_header "در حال راه‌اندازی سرور خارجی"

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

  echo "$PUBLIC_KEY" > /root/foreign_pubkey.txt

  # تست بعد از نصب
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
  echo
  echo "  ${WG_CMD%-quick} set $WG_IFACE peer <PUBLIC_KEY_IRAN> allowed-ips 10.8.0.2/32"
  echo "  ${WG_CMD%-quick}-quick save $WG_IFACE"
  echo
  log "INSTALL" "foreign server installed successfully"
}

# ─────────────────────────────────────────────
# نصب سرور ایران
# ─────────────────────────────────────────────
install_iran() {
  show_header "در حال راه‌اندازی سرور ایران"

  install_amneziawg
  apt install -y curl

  read -p "IP داخلی سرور ایران (پیشنهاد: 10.8.0.2): " WG_IP
  WG_IP=${WG_IP:-10.8.0.2}
  read -p "IP عمومی سرور خارجی: " FOREIGN_IP
  read -p "پورت تونل سرور خارجی (پیشفرض: 51820): " WG_PORT
  WG_PORT=${WG_PORT:-51820}
  read -p "کلید عمومی سرور خارجی: " FOREIGN_PUBLIC_KEY

  # IP داخلی سرور خارجی برای تست و health check
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
    show_error "نصب 3X-UI با خطا مواجه شد، لطفاً دستی نصب کنید:"
    echo "  bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
  }

  ufw allow ssh
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 54321/tcp
  ufw --force enable

  echo "$PUBLIC_KEY" > /root/iran_pubkey.txt

  # تست بعد از نصب
  run_post_install_test "iran" "$FOREIGN_WG_IP"

  show_success "نصب سرور ایران تکمیل شد!"
  PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || echo "نامشخص")
  show_info "پنل مدیریت 3X-UI: http://${PUBLIC_IP}:54321"
  show_info "نام کاربری پیشفرض: admin  |  رمز عبور پیشفرض: admin"
  echo -e "  ${RED}⚠️  رمز عبور را بلافاصله تغییر دهید!${NC}"
  echo
  show_info "کلید عمومی سرور ایران:"
  echo "  $PUBLIC_KEY"
  echo
  show_info "مرحله آخر — روی سرور خارجی اجرا کنید:"
  echo "  ${WG_CMD%-quick} set $WG_IFACE peer $PUBLIC_KEY allowed-ips $WG_IP/32"
  echo "  ${WG_CMD%-quick}-quick save $WG_IFACE"
  echo
  log "INSTALL" "iran server installed successfully"
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
