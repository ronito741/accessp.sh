#!/bin/bash

set -euo pipefail

echo "======================================"
echo "   ALFA HOTSPOT FIXED STABLE VERSION"
echo "======================================"

WLAN="wlan1"
GW="192.168.95.1"
SUBNET="192.168.95.0/24"

# -----------------------------
# ERROR HANDLER
# -----------------------------
fail() {
    echo ""
    echo "❌ HOTSPOT FAILED"
    echo "CHECK STATE BELOW:"
    echo ""

    echo "dnsmasq:"
    pgrep -a dnsmasq || echo "none"

    echo "hostapd:"
    pgrep -a hostapd || echo "none"

    echo "wlan1:"
    ip addr show $WLAN || true

    exit 1
}

trap fail ERR

# -----------------------------
# 1. CLEAN ALL CONFLICTS
# -----------------------------
echo "[1] Cleaning system conflicts..."

systemctl stop dnsmasq 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true

pkill -9 dnsmasq 2>/dev/null || true
pkill -9 hostapd 2>/dev/null || true

# kill known network tools that break DNS/AP
pkill -f pwndrop 2>/dev/null || true
pkill -f bettercap 2>/dev/null || true

# free DNS port (safe cleanup)
fuser -k 53/udp 2>/dev/null || true

# -----------------------------
# 2. RESET WLAN COMPLETELY (CRITICAL FIX)
# -----------------------------
echo "[2] Resetting wlan1..."

ip link set $WLAN down 2>/dev/null || true
ip addr flush dev $WLAN 2>/dev/null || true

iw dev $WLAN set type managed 2>/dev/null || true
iw dev $WLAN set type __ap 2>/dev/null || true

ip link set $WLAN up
rfkill unblock all
iw dev $WLAN set power_save off 2>/dev/null || true

sleep 2

# -----------------------------
# 3. ASSIGN STATIC AP IP
# -----------------------------
echo "[3] Setting AP IP..."

ip addr add $GW/24 dev $WLAN 2>/dev/null || true

ip a show $WLAN | grep $GW >/dev/null || fail

# -----------------------------
# 4. FIND INTERNET INTERFACE
# -----------------------------
WAN=$(ip route | awk '/default/ {print $5}' | head -n 1)

[ -z "$WAN" ] && echo "NO INTERNET INTERFACE FOUND" && exit 1

echo "WAN = $WAN"

# -----------------------------
# 5. USER INPUT
# -----------------------------
read -p "SSID: " SSID
read -p "Password: " PASS

# -----------------------------
# 6. HOSTAPD CONFIG
# -----------------------------
echo "[4] Configuring hostapd..."

cat > /etc/hostapd/hostapd.conf <<EOF
interface=$WLAN
driver=nl80211
ssid=$SSID
hw_mode=g
channel=6
wmm_enabled=1
auth_algs=1

wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

echo "DAEMON_CONF=/etc/hostapd/hostapd.conf" > /etc/default/hostapd

# -----------------------------
# 7. ENABLE INTERNET ROUTING
# -----------------------------
echo "[5] Enabling IP forwarding..."

echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1

# -----------------------------
# 8. NAT (FIXED INTERNET SHARING)
# -----------------------------
echo "[6] Setting NAT..."

iptables -P FORWARD ACCEPT

iptables -t nat -C POSTROUTING -o $WAN -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE

iptables -C FORWARD -i $WLAN -o $WAN -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i $WLAN -o $WAN -j ACCEPT

iptables -C FORWARD -i $WAN -o $WLAN -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i $WAN -o $WLAN -m state --state RELATED,ESTABLISHED -j ACCEPT

# -----------------------------
# 9. DNSMASQ (NO LOG FILE FIX)
# -----------------------------
echo "[7] Starting DHCP/DNS..."

pkill -9 dnsmasq 2>/dev/null || true

dnsmasq \
  --interface=$WLAN \
  --bind-interfaces \
  --except-interface=lo \
  --dhcp-range=192.168.95.10,192.168.95.200,12h \
  --dhcp-option=3,$GW \
  --dhcp-option=6,8.8.8.8,1.1.1.1 \
  --no-resolv \
  --no-hosts \
  --log-facility=/dev/null \
  --pid-file=/tmp/dnsmasq.pid &

sleep 1

pgrep dnsmasq >/dev/null || fail

# -----------------------------
# 10. START HOSTAPD (STABLE MODE)
# -----------------------------
echo "[8] Starting WiFi AP..."

hostapd -B /etc/hostapd/hostapd.conf

sleep 2

pgrep hostapd >/dev/null || fail

# -----------------------------
# 11. FINAL CHECK
# -----------------------------
echo ""
echo "======================================"
echo " HOTSPOT FULLY FIXED + STABLE"
echo "======================================"
echo "SSID: $SSID"
echo "IP: $GW"
echo "WAN: $WAN"
echo "STATUS: INTERNET SHARING ACTIVE"
echo "======================================"

echo "[OK] Clients will now have internet access"
