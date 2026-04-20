#! /bin/bash

# dependecies needed:
# hostapd
# dnsmasq
# iptables
# iw
# net-tools
# util-linux
# iproute2


get_subnet() {
  local octet_3=10

  while true; do
    local subnet="192.168.${octet_3}"
    if ! ip addr | grep -q "${subnet}."; then
      echo "$subnet"
      return 0
    fi 

    octet_3=$((octet_3 + 1))

    if [ $octet_3 -gt 254 ]; then
      return 1
    fi 
  done
}

ieee80211_frequency_to_channel() {
    local FREQ_MAYBE_FRACTIONAL=$1
    local FREQ=${FREQ_MAYBE_FRACTIONAL%.*}


  # ---- generate hostapd c
    if [[ $FREQ -lt 1000 ]]; then
        echo 0
    elif [[ $FREQ -eq 2484 ]]; then
        echo 14
    elif [[ $FREQ -eq 5935 ]]; then
        echo 2
    elif [[ $FREQ -lt 2484 ]]; then
        echo $(( ($FREQ - 2407) / 5 ))
    elif [[ $FREQ -ge 4910 && $FREQ -le 4980 ]]; then
        echo $(( ($FREQ - 4000) / 5 ))
    elif [[ $FREQ -lt 5950 ]]; then
        echo $(( ($FREQ - 5000) / 5 ))
    elif [[ $FREQ -le 45000 ]]; then
        echo $(( ($FREQ - 5950) / 5 ))
    elif [[ $FREQ -ge 58320 && $FREQ -le 70200 ]]; then
        echo $(( ($FREQ - 56160) / 2160 ))
    else
        echo 0
    fi
}

get_wifi_interface() {
  local phy_path=$(ls -d /sys/class/ieee80211/phy* 2>/dev/null | head -n 1)
  if [ -z "$phy_path" ]; then
    return 1
  fi

  local iface=$(ls "$phy_path/device/net" 2>/dev/null | grep '^w' | grep -v "_ap" | head -n 1)
  if [ -z "$iface" ]; then
    return 1
  fi

  echo "$iface"
}

get_new_virt_mac() {
  local phy_mac=$(cat /sys/class/net/$IFACE_PHY/address)
  echo $phy_mac | awk -F: '{printf "02:%s:%s:%s:%s:%s", $2, $3, $4, $5, $6}'
}

delete_virt_interface() {
  if ip link show "$IFACE_VIRT" > /dev/null 2>&1; then
    sudo ip link set "$IFACE_VIRT" down 2>/dev/null
    sudo iw dev "$IFACE_VIRT" del 2>/dev/null
  fi
}

manage_nm_state() {
  local iface=$1
  local state=$2

  if command -v nmcli > /dev/null; then
    sudo nmcli device set "$iface" managed "$state" 2>/dev/null 
  fi
}

if [[ $EUID -ne 0 ]]; then
  echo "No permission given"
  exit 1
fi

# ---- default config and cli ----
SSID="linux-hotspot"
PASS="12345678"
PID_FILE="/tmp/hotspot.pid"
IFACE_FILE="/tmp/hotspot.iface"
CONFDIR="/tmp/hotspot"

usage() {
  echo "Usage: sudo $0 <start|stop|status> [-s ssid] [-p password]"
  echo "  start     Start the hotspot"
  echo "  stop      Stop the hotspot"
  echo "  status    Show hotspot status"
  echo "  -s        SSID for the hotspot (default: $SSID)"
  echo "  -p        Password (min 8 chars, default: $PASS)"
  exit 1
}

COMMAND="$1"
shift || true

while getopts "s:p:h" opt; do
  case $opt in
    s) SSID="$OPTARG" ;;
    p) PASS="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
#-----------------------------------

hotspot_stop() {
  echo "Stopping hotspot..."

  if [ -f "$IFACE_FILE" ]; then
    source "$IFACE_FILE"
  fi

  # kill hostapd
  if [ -f "$PID_FILE" ]; then
    HOSTAPD_PID=$(cat "$PID_FILE")
    if kill -0 "$HOSTAPD_PID" 2>/dev/null; then
      sudo kill "$HOSTAPD_PID"
    fi
    rm -f "$PID_FILE" 2>/dev/null
  fi

  # remove iptables rules
  if [ -n "$IFACE_PHY" ] && [ -n "$IFACE_VIRT" ]; then
    sudo iptables -t nat -D POSTROUTING -o "$IFACE_PHY" -j MASQUERADE 2>/dev/null
    sudo iptables -D FORWARD -i "$IFACE_PHY" -o "$IFACE_VIRT" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    sudo iptables -D FORWARD -i "$IFACE_VIRT" -o "$IFACE_PHY" -j ACCEPT 2>/dev/null
  fi

  # remove virtual interface and kill dnsmasq
  if [ -n "$IFACE_VIRT" ]; then
    sudo pkill -f "dnsmasq -i $IFACE_VIRT" 2>/dev/null
    delete_virt_interface
  fi

  rm -f "$IFACE_FILE" 2>/dev/null
  rm -f "$HOSTAPD_CONF" 2>/dev/null
  echo "Hotspot stopped."
}

hotspot_status() {
  if [ ! -f "$PID_FILE" ]; then
    echo "Hotspot: stopped"
    return
  fi

  HOSTAPD_PID=$(cat "$PID_FILE")
  if kill -0 "$HOSTAPD_PID" 2>/dev/null; then
    if [ -f "$IFACE_FILE" ]; then
      source "$IFACE_FILE"
    fi

    CLIENT_COUNT=$(arp -n -i "$IFACE_VIRT" 2>/dev/null | grep -c "$IFACE_VIRT")

    echo "Hotspot: running"
    echo "  SSID     : ${SSID}"
    echo "  Interface: $IFACE_VIRT"
    echo "  Gateway  : $GATEWAY_IP"
    echo "  Clients  : $CLIENT_COUNT"
  else
    echo "Hotspot: stopped (stale pid found, cleaning up)"
    rm -f "$PID_FILE"
  fi
}

hotspot_start() {
  if [ ${#PASS} -lt 8 ]; then
    echo "Error: Password must be at least 8 characters long"
    exit 1
  fi

  # exit if AP mode is not found
  if ! iw list | grep -q "AP"; then
    echo "Error: AP mode not supported"
    exit 1
  fi

  TOTAL_IFACES=$(iw list | sed -n '/#{.*AP.*}/,/total <=/p' | grep -oP 'total <= \K\d+')
  if [ "$TOTAL_IFACES" -lt 2 ]; then
    echo "Error: Limited interfaces, hotspot not supported"
    exit 1
  fi

  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Hotspot is already running. Use 'stop' first."
    exit 1
  fi

  mkdir -p "$CONFDIR"

  # IFACE_PHY=$(ip route | grep default | grep -oP 'dev \K\w+' | grep '^w'| head -n 1)
  IFACE_PHY=$(get_wifi_interface)
  if [ $? -ne 0 ]; then
    echo "Error: No wifi interface found"
    exit 1
  fi

  IFACE_VIRT="${IFACE_PHY}_ap"

  trap hotspot_stop sigint sigterm

  echo "IFACE_PHY=$IFACE_PHY" > "$IFACE_FILE"
  echo "IFACE_VIRT=$IFACE_VIRT" >> "$IFACE_FILE"
  echo "SSID=$SSID" >> "$IFACE_FILE"

  # remove any previous instances of the virtual interface
  delete_virt_interface

  SUBNET=$(get_subnet)
  GATEWAY_IP="${SUBNET}.1"
  DHCP_RANGE="${SUBNET}.10,${SUBNET}.100"
  echo "GATEWAY_IP=$GATEWAY_IP" >> "$IFACE_FILE"

  # create a virtual interface in AP mode
  # unmanage the interface if NetworkMnanager id present
  # set a new mac address and the gateway ip for the virtual interface
  sudo iw dev "$IFACE_PHY" interface add "$IFACE_VIRT" type __ap
  sudo iw dev "$IFACE_VIRT" set type __ap
  manage_nm_state "$IFACE_VIRT" "no"
  sudo ip link set dev "$IFACE_VIRT" address "$(get_new_virt_mac)"
  sudo ip addr add "$GATEWAY_IP/24" dev "$IFACE_VIRT"

  # ---- generate hostapd config ----
  HOSTAPD_CONF="$CONFDIR/hostapd.conf"
  HW_MODE="g"
  CHANNEL=6

  # get the frequency of the current wifi connection and set channel
  FREQ=$(iw dev "$IFACE_PHY" link | grep -i freq | awk '{print $2}' | grep -oP '^\d+')
  CHANNEL=$(ieee80211_frequency_to_channel "$FREQ")

  echo "Detected frequency: ${FREQ} MHz, using channel: ${CHANNEL}"

  if [ "$CHANNEL" -eq 0 ]; then
    CHANNEL=6
    HW_MODE="g"
  else
    if [ "$FREQ" -ge 4000 ]; then
      HW_MODE="a"
    else
      HW_MODE="g"
    fi
  fi

  cat <<EOF > "$HOSTAPD_CONF"
interface=$IFACE_VIRT
driver=nl80211
ssid=$SSID
hw_mode=$HW_MODE
channel=$CHANNEL
wpa_passphrase=$PASS
wpa=2
wpa_key_mgmt=WPA-PSK SAE
ieee80211w=1
ieee80211n=1
wmm_enabled=1
wpa_pairwise=CCMP
rsn_pairwise=CCMP
EOF
# -----------------------------------

  # kill previous dnsmasq instance
  sudo pkill -f "dnsmasq -i $IFACE_VIRT" 2> /dev/null

  # start dhcp server
  sudo dnsmasq -i "$IFACE_VIRT" --port=0 --dhcp-range="$DHCP_RANGE,12h" --dhcp-option=6,8.8.8.8,8.8.4.4 --no-daemon &

  # enable ip forwarding
  sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null

  # setup NAT and firewall rules
  sudo iptables -t nat -A POSTROUTING -o "$IFACE_PHY" -j MASQUERADE
  sudo iptables -A FORWARD -i "$IFACE_PHY" -o "$IFACE_VIRT" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  sudo iptables -A FORWARD -i "$IFACE_VIRT" -o "$IFACE_PHY" -j ACCEPT

  # start hostapd in the background and pid is saved to the pid file
  sudo hostapd -B -P "$PID_FILE" "$HOSTAPD_CONF" > /tmp/hostapd.log 2>&1
  sleep 1

  # check pid file if hostapd is running, kill if not
  if [ ! -f "$PID_FILE" ] || ! kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    echo "Failed to start hostapd. Log:"
    cat /tmp/hostapd.log
    hotspot_stop
    exit 1
  fi

  echo "Hotspot started (SSID: $SSID)"
}

case "$COMMAND" in
  start)  hotspot_start ;;
  stop)   hotspot_stop ;;
  status) hotspot_status ;;
  *)      usage ;;
esac

