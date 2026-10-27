#!/usr/bin/env bash
# check-step2-storage01.sh - Step 2 (network Fabric A / Fabric B), storage01 ONLY.
# Read-only: changes nothing.

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $1"; }

# name | interface | expected own address | client01 address
FABRICS=(
  "fabricA enp0s8 192.168.56.10/24 192.168.56.20"
  "fabricB enp0s9 192.168.57.10/24 192.168.57.20"
)

echo "== 1. Hostname"
if [[ "$(hostname)" == "storage01" ]]; then
  ok "hostname = storage01"
else
  bad "hostname = $(hostname), expected storage01 - you may be on the wrong VM"
fi

for f in "${FABRICS[@]}"; do
  read -r CON IF ADDR PEER <<< "$f"
  echo "== ${CON} (${IF})"

  if ip link show "$IF" >/dev/null 2>&1; then
    STATE="$(ip -br link show "$IF" | awk '{print $2}')"
    if [[ "$STATE" == "UP" ]]; then
      ok "$IF exists and is UP"
    else
      bad "$IF state is $STATE (check Cable Connected in VirtualBox)"
    fi
  else
    bad "$IF not found (check Adapter in VirtualBox, run: ip -br link)"
    continue
  fi

  if nmcli -t -f NAME con show | grep -qx "$CON"; then
    ok "connection $CON exists"
  else
    bad "connection $CON does not exist"
  fi

  ACTIVE_DEV="$(nmcli -t -f NAME,DEVICE con show --active | grep "^${CON}:" | cut -d: -f2)"
  if [[ "$ACTIVE_DEV" == "$IF" ]]; then
    ok "$CON is active on $IF"
  else
    bad "$CON is not active on $IF (run: sudo nmcli con up $CON)"
  fi

  METHOD="$(nmcli -g ipv4.method con show "$CON" 2>/dev/null)"
  if [[ "$METHOD" == "manual" ]]; then
    ok "$CON uses a static address (manual)"
  else
    bad "$CON ipv4.method = ${METHOD:-none}, expected manual"
  fi

  ADDRS="$(ip -4 -o addr show dev "$IF" | awk '{print $4}' | xargs)"
  if [[ "$ADDRS" == "$ADDR" ]]; then
    ok "$IF has exactly $ADDR"
  else
    bad "$IF addresses: '${ADDRS:-none}', expected only $ADDR"
  fi

  OTHERS="$(nmcli -t -f NAME,DEVICE con show | awk -F: -v d="$IF" -v c="$CON" '$2==d && $1!=c {print $1}')"
  if [[ -z "$OTHERS" ]]; then
    ok "no other connection on $IF"
  else
    bad "extra connection(s) on $IF: $OTHERS (delete with: sudo nmcli con delete \"<name>\")"
  fi

  # MAC of this adapter - compare with VirtualBox Settings -> Network -> Advanced
  info "$IF MAC: $(cat /sys/class/net/$IF/address)"

  if ping -c 3 -W 1 -I "$IF" "$PEER" >/dev/null 2>&1; then
    ok "ping $PEER (client01) via $IF: 0% loss"
  else
    bad "ping $PEER (client01) via $IF failed"
  fi
done

echo "== Routing"
DEFAULTS="$(ip route show default | wc -l)"
DEFAULT_DEV="$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | xargs)"
if [[ "$DEFAULTS" -eq 1 && "$DEFAULT_DEV" == "enp0s3" ]]; then
  ok "one default route, via enp0s3 (NAT)"
else
  bad "default route(s): count=$DEFAULTS dev='$DEFAULT_DEV', expected 1 via enp0s3"
fi

echo "== Firewall (ping must not be blocked)"
if systemctl is-active --quiet firewalld; then
  BLOCKED="$(firewall-cmd --list-icmp-blocks 2>/dev/null)"
  if [[ "$BLOCKED" != *"echo-request"* ]]; then
    ok "firewalld does not block ping (echo-request)"
  else
    bad "firewalld blocks echo-request"
  fi
  info "active zones: $(firewall-cmd --get-active-zones | tr '\n' ' ')"
else
  info "firewalld is not running"
fi

echo
echo "Result: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]