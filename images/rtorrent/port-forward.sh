#!/bin/sh

set -x
trap '' HUP

TO=10000

while [ "x$VPN_INF" = "x" ]; do
  export VPN_INF=$(wg show interfaces | head -n 1)
  sleep 5
done

function set_port() {
  nft add table ip nat
  nft add chain ip nat PREROUTING { type nat hook prerouting priority 0 \; }

  nft -a list table ip nat | grep -E " $1 dport [0-9]+ redirect to :$TO" | rev | awk '{print $1}' | while read -r handle; do
    nft delete rule ip nat PREROUTING handle $handle
  done

  nft add rule ip nat PREROUTING iif $VPN_INF $1 dport $2 redirect to $TO
}

lastTcp=0
lastUdp=0

while true ; do
  date
  udpPort=$(natpmpc -a 1 0 udp 60 -g 10.2.0.1 | grep -oP '(?<=Mapped public port )([0-9]+)')
  echo "Got udp port $udpPort"
  tcpPort=$(natpmpc -a 1 0 tcp 60 -g 10.2.0.1 | grep -oP '(?<=Mapped public port )([0-9]+)')
  echo "Got tcp port $tcpPort"

  if [ "0$lastTcp" -ne "0$tcpPort" ]; then
    set_port tcp $tcpPort
  fi

  if [ "0$lastUdp" -ne "0$udpPort" ]; then
    set_port udp $udpPort
  fi

  lastTcp=$tcpPort
  lastUdp=$udpPort

  sleep 45
done
