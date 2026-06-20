#!/bin/bash
set -e

# رنگ‌ها و تنظیمات نمایش
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
LINE="================================================================"

show_error()   { echo -e "${RED}❌ $1${NC}"; }
show_success() { echo -e "${GREEN}✅ $1${NC}"; }
show_info()    { echo -e "${YELLOW}🔹 $1${NC}"; }
show_header()  { echo -e "${CYAN}$LINE\n$1\n$LINE${NC}"; }

# ─────────────────────────────────────────────
# بررسی دسترسی root
# ─────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  show_error "لطفاً این اسکریپت را با دسترسی root اجرا کنید"
  exit 1
fi

# ─────────────────────────────────────────────
# [FIX 1] نصب AmneziaWG به جای WireGuard معمولی
# AmneziaWG ترافیک UDP را obfuscate می‌کند و
# از شناسایی توسط DPI فیلترینگ ایران جلوگیری می‌کند
# ─────────────────────────────────────────────
install_amneziawg() {
  show_info "نصب AmneziaWG (ضد فیلتر)..."
  apt update -qq

  # تلاش برای نصب از PPA رسمی
  if ! command -v awg-quick &>/dev/null; then
    apt install -y software-properties-common
    add-apt-repository -y ppa:amnezia/ppa 2>/dev/null || true
    apt update -qq
    apt install -y amneziawg amneziawg-tools || {
      # fallback: نصب از طریق DKMS
      show_info "PPA در دسترس نیست، تلاش از طریق DKMS..."
      apt install -y wireguard-dkms wireguard-tools linux-headers-$(uname -r) curl git make gcc
    }
  fi
}

# ─────────────────────────────────────────────
# منوی اصلی
# ─────────────────────────────────────────────
show_header "نصب خودکار AmneziaWG + 3X-UI"
echo "1) نصب روی سرور خارجی"
echo "2) نصب روی سرور ایران"
echo "3) خروج"
read -p "لطفاً گزینه مورد نظر را انتخاب کنید (1-3): " choice

# ─────────────────────────────────────────────
# نصب سرور خارجی
# ─────────────────────────────────────────────
install_foreign() {
  show_header "در حال راه‌اندازی سرور خارجی"

  # [FIX 1] نصب AmneziaWG به جای wireguard
  install_amneziawg
  apt install -y curl qrencode iptables-persistent

  # تولید کلیدها
  show_info "تولید کلیدهای رمزنگاری..."
  umask 077
  mkdir -p /etc/amnezia/amneziawg

  # [FIX 1] استفاده از awg به جای wg
  if command -v awg &>/dev/null; then
    awg genkey | tee /etc/amnezia/amneziawg/private.key | awg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="awg-quick"
    WG_CONF_DIR="/etc/amnezia/amneziawg"
    WG_IFACE="awg0"
  else
    # fallback به wireguard معمولی در صورت عدم نصب AmneziaWG
    show_info "AmneziaWG نصب نشد، fallback به WireGuard..."
    apt install -y wireguard
    wg genkey | tee /etc/amnezia/amneziawg/private.key | wg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="wg-quick"
    WG_CONF_DIR="/etc/wireguard"
    WG_IFACE="wg0"
  fi

  PRIVATE_KEY=$(cat /etc/amnezia/amneziawg/private.key)
  PUBLIC_KEY=$(cat /etc/amnezia/amneziawg/public.key)

  # دریافت اطلاعات
  read -p "IP داخلی سرور خارجی (پیشنهاد: 10.8.0.1): " WG_IP
  WG_IP=${WG_IP:-10.8.0.1}
  read -p "پورت تونل (پیشفرض: 51820): " WG_PORT
  WG_PORT=${WG_PORT:-51820}

  # [FIX 4] escape کردن $() در heredoc با single quote روی EOF
  # تا در زمان اجرای wg-quick مقدار واقعی interface خوانده شود
  WAN_IF=$(ip route show default | awk '/default/ {print $5; exit}')

  mkdir -p "$WG_CONF_DIR"
  cat > "$WG_CONF_DIR/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $WG_IP/24
ListenPort = $WG_PORT
SaveConfig = false

# [FIX 4] interface در زمان نوشتن فایل مشخص شد نه موقع اجرا
PostUp   = iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE; iptables -A FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -A FORWARD -o ${WG_IFACE} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE; iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_IFACE} -j ACCEPT
EOF

  # فعال‌سازی IP Forwarding
  if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  sysctl -p

  # فعال‌سازی سرویس
  systemctl enable --now "${WG_CMD}@${WG_IFACE}"

  # فایروال
  ufw allow "$WG_PORT/udp"
  ufw allow ssh
  ufw --force enable

  # ذخیره کلید عمومی در فایل برای مرحله بعد
  echo "$PUBLIC_KEY" > /root/foreign_pubkey.txt
  show_success "نصب سرور خارجی تکمیل شد!"
  show_info "کلید عمومی سرور خارجی: $PUBLIC_KEY"
  echo
  echo "──── QR کد کلید عمومی ────"
  qrencode -t ansiutf8 "$PUBLIC_KEY"
  echo

  # [FIX 5] راهنمای واضح برای اتصال دو طرفه
  show_info "مرحله بعد:"
  echo "  ۱. اسکریپت را روی سرور ایران اجرا کنید (گزینه ۲)"
  echo "  ۲. کلید عمومی سرور ایران را بخواهید"
  echo "  ۳. روی همین سرور خارجی دستور زیر را اجرا کنید:"
  echo
  echo "  ${WG_CMD%-quick} set $WG_IFACE peer <PUBLIC_KEY_IRAN> allowed-ips 10.8.0.2/32"
  echo "  ${WG_CMD%-quick}-quick save $WG_IFACE"
  echo
  echo "  (کلید عمومی سرور خارجی در /root/foreign_pubkey.txt ذخیره شد)"
}

# ─────────────────────────────────────────────
# نصب سرور ایران
# ─────────────────────────────────────────────
install_iran() {
  show_header "در حال راه‌اندازی سرور ایران"

  # [FIX 1] نصب AmneziaWG
  install_amneziawg
  apt install -y curl

  # دریافت اطلاعات
  read -p "IP داخلی سرور ایران (پیشنهاد: 10.8.0.2): " WG_IP
  WG_IP=${WG_IP:-10.8.0.2}
  read -p "IP عمومی سرور خارجی: " FOREIGN_IP
  read -p "پورت تونل سرور خارجی (پیشفرض: 51820): " WG_PORT
  WG_PORT=${WG_PORT:-51820}
  read -p "کلید عمومی سرور خارجی: " FOREIGN_PUBLIC_KEY

  # تولید کلیدها
  show_info "تولید کلیدهای رمزنگاری..."
  umask 077
  mkdir -p /etc/amnezia/amneziawg

  if command -v awg &>/dev/null; then
    awg genkey | tee /etc/amnezia/amneziawg/private.key | awg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="awg-quick"
    WG_CONF_DIR="/etc/amnezia/amneziawg"
    WG_IFACE="awg0"
  else
    show_info "AmneziaWG نصب نشد، fallback به WireGuard..."
    apt install -y wireguard
    wg genkey | tee /etc/amnezia/amneziawg/private.key | wg pubkey > /etc/amnezia/amneziawg/public.key
    WG_CMD="wg-quick"
    WG_CONF_DIR="/etc/wireguard"
    WG_IFACE="wg0"
  fi

  PRIVATE_KEY=$(cat /etc/amnezia/amneziawg/private.key)
  PUBLIC_KEY=$(cat /etc/amnezia/amneziawg/public.key)

  # [FIX 2] ذخیره gateway فعلی قبل از راه‌اندازی تونل
  # تا SSH قطع نشود
  DEFAULT_GW=$(ip route show default | awk '/default/ {print $3; exit}')
  DEFAULT_IF=$(ip route show default | awk '/default/ {print $5; exit}')

  mkdir -p "$WG_CONF_DIR"
  cat > "$WG_CONF_DIR/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $WG_IP/24
DNS = 8.8.8.8, 1.1.1.1

# [FIX 2] حفظ مسیر SSH و endpoint قبل از تغییر default route
# wg-quick با AllowedIPs=0.0.0.0/0 خودش endpoint را exclude می‌کند
# اما SSH client را باید دستی exclude کنیم
PostUp   = ip route add $FOREIGN_IP via $DEFAULT_GW dev $DEFAULT_IF 2>/dev/null || true
PostDown = ip route del $FOREIGN_IP via $DEFAULT_GW dev $DEFAULT_IF 2>/dev/null || true

[Peer]
PublicKey = $FOREIGN_PUBLIC_KEY
Endpoint = $FOREIGN_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  # [FIX 3] حذف wg-route.service اضافی
  # wg-quick خودش با AllowedIPs=0.0.0.0/0 مسیردهی را مدیریت می‌کند
  # اضافه کردن دستی "ip route add default dev wg0" باعث conflict می‌شد

  # فعال‌سازی سرویس
  systemctl enable --now "${WG_CMD}@${WG_IFACE}"

  # تست اتصال تونل
  show_info "بررسی اتصال تونل..."
  sleep 3
  if ping -c 2 -W 3 10.8.0.1 &>/dev/null; then
    show_success "تونل به سرور خارجی وصل شد!"
  else
    show_error "تونل وصل نشد — کلیدها و IP سرور خارجی را بررسی کنید"
    echo "می‌توانید با دستور زیر وضعیت تونل را ببینید:"
    echo "  ${WG_CMD%-quick} show ${WG_IFACE}"
  fi

  # [FIX 6] نصب 3X-UI به جای vaxilu/x-ui که منسوخ شده
  show_info "در حال نصب پنل 3X-UI..."
  bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y" || {
    show_error "نصب 3X-UI با خطا مواجه شد، لطفاً دستی نصب کنید:"
    echo "  bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
    # بدون exit تا بقیه تنظیمات ادامه یابد
  }

  # تنظیم فایروال
  ufw allow ssh
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 54321/tcp
  ufw --force enable

  # ذخیره کلید عمومی
  echo "$PUBLIC_KEY" > /root/iran_pubkey.txt

  # نمایش اطلاعات
  show_success "نصب سرور ایران تکمیل شد!"
  PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || echo "نامشخص")
  show_info "پنل مدیریت 3X-UI: http://${PUBLIC_IP}:54321"
  show_info "نام کاربری پیشفرض: admin"
  show_info "رمز عبور پیشفرض: admin"
  echo
  show_info "کلید عمومی سرور ایران (برای سرور خارجی لازم است):"
  echo "  $PUBLIC_KEY"
  echo
  echo "  (در /root/iran_pubkey.txt هم ذخیره شد)"
  echo
  # [FIX 5] راهنمای واضح برای تکمیل اتصال دو طرفه
  show_info "مرحله آخر — روی سرور خارجی اجرا کنید:"
  echo "  ${WG_CMD%-quick} set awg0 peer $PUBLIC_KEY allowed-ips 10.8.0.2/32"
  echo "  ${WG_CMD%-quick}-quick save awg0"
}

# ─────────────────────────────────────────────
# اجرای گزینه انتخابی
# ─────────────────────────────────────────────
case $choice in
  1) install_foreign ;;
  2) install_iran ;;
  3) exit 0 ;;
  *) show_error "گزینه نامعتبر!"; exit 1 ;;
esac
