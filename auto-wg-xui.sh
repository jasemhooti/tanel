#!/bin/bash
set -e

# رنگ‌ها و تنظیمات نمایش
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
LINE="================================================================"

# تابع‌های کمکی
show_error() { echo -e "${RED}❌ $1${NC}"; }
show_success() { echo -e "${GREEN}✅ $1${NC}"; }
show_info() { echo -e "${YELLOW}🔹 $1${NC}"; }
show_header() { echo -e "${GREEN}$LINE\n$1\n$LINE${NC}"; }

# بررسی دسترسی root
if [ "$EUID" -ne 0 ]; then
  show_error "لطفاً این اسکریپت را با دسترسی root اجرا کنید"
  exit 1
fi

# منوی اصلی
show_header "نصب خودکار WireGuard + X-UI"
echo "1) نصب روی سرور خارجی"
echo "2) نصب روی سرور ایران"
echo "3) خروج"
read -p "لطفاً گزینه مورد نظر را انتخاب کنید (1-3): " choice

# تابع‌های نصب
install_foreign() {
  show_header "در حال راه‌اندازی سرور خارجی"
  
  # نصب وابستگی‌ها
  show_info "نصب بسته‌های ضروری..."
  apt update && apt install -y wireguard curl qrencode iptables-persistent
  
  # تولید کلیدها
  show_info "تولید کلیدهای رمزنگاری..."
  umask 077
  wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
  PRIVATE_KEY=$(cat /etc/wireguard/private.key)
  PUBLIC_KEY=$(cat /etc/wireguard/public.key)
  
  # دریافت اطلاعات
  read -p "IP داخلی سرور خارجی (پیشنهاد: 10.8.0.1): " WG_IP
  read -p "پورت WireGuard (پیشفرض: 51820): " WG_PORT
  WG_PORT=${WG_PORT:-51820}
  
  # تنظیمات WireGuard
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $WG_IP/24
ListenPort = $WG_PORT
SaveConfig = true

# فعال‌سازی NAT
PostUp = iptables -t nat -A POSTROUTING -o $(ip route show default | awk '/default/ {print $5}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $(ip route show default | awk '/default/ {print $5}') -j MASQUERADE
EOF

  # فعال‌سازی فورواردینگ
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p

  # فعال‌سازی سرویس
  systemctl enable --now wg-quick@wg0
  ufw allow $WG_PORT/udp
  ufw allow ssh
  ufw --force enable

  # نمایش اطلاعات
  show_success "نصب سرور خارجی تکمیل شد!"
  show_info "کلید عمومی سرور خارجی: $PUBLIC_KEY"
  echo "برای اسکن QR کد:"
  qrencode -t ansiutf8 "$PUBLIC_KEY"
  echo
  show_info "پس از نصب سرور ایران، کلید عمومی سرور ایران را با دستور زیر اضافه کنید:"
  echo "wg set wg0 peer <کلید-عمومی-ایران> allowed-ips 10.8.0.2/32"
  echo "سپس دستور زیر را برای ذخیره‌سازی پیکربندی اجرا کنید:"
  echo "wg-quick save wg0"
}

install_iran() {
  show_header "در حال راه‌اندازی سرور ایران"
  
  # نصب وابستگی‌ها
  show_info "نصب بسته‌های ضروری..."
  apt update && apt install -y wireguard curl
  
  # دریافت اطلاعات
  read -p "IP داخلی سرور ایران (پیشنهاد: 10.8.0.2): " WG_IP
  read -p "IP عمومی سرور خارجی: " FOREIGN_IP
  read -p "پورت WireGuard سرور خارجی (پیشفرض: 51820): " WG_PORT
  WG_PORT=${WG_PORT:-51820}
  read -p "کلید عمومی سرور خارجی: " FOREIGN_PUBLIC_KEY
  
  # تولید کلیدها
  show_info "تولید کلیدهای رمزنگاری..."
  umask 077
  wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
  PRIVATE_KEY=$(cat /etc/wireguard/private.key)
  PUBLIC_KEY=$(cat /etc/wireguard/public.key)
  
  # تنظیمات WireGuard
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $WG_IP/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $FOREIGN_PUBLIC_KEY
Endpoint = $FOREIGN_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  # فعال‌سازی سرویس
  systemctl enable --now wg-quick@wg0
  
  # تغییر مسیر پیش‌فرض به تونل
  ip route add default dev wg0
  
  # ذخیره تغییرات مسیریابی
  cat > /etc/systemd/system/wg-route.service <<EOF
[Unit]
Description=Add default route for WireGuard
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ip route add default dev wg0

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable --now wg-route

  # نصب X-UI
  show_info "در حال نصب پنل X-UI..."
  bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh) <<< "y"
  
  # تنظیم فایروال
  ufw allow ssh
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 54321/tcp
  ufw --force enable

  # نمایش اطلاعات
  show_success "نصب سرور ایران تکمیل شد!"
  show_info "پنل مدیریت X-UI: http://$(curl -s ifconfig.me):54321"
  show_info "نام کاربری: admin"
  show_info "رمز عبور: admin"
  show_info "کلید عمومی سرور ایران: $PUBLIC_KEY"
}

# اجرای گزینه انتخابی
case $choice in
  1) install_foreign ;;
  2) install_iran ;;
  3) exit 0 ;;
  *) show_error "گزینه نامعتبر!"; exit 1 ;;
esac
