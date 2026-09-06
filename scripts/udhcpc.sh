#!/bin/sh
#
# udhcpc.sh - skrypt dla udhcpc z busyboksa (odpowiednik default.script).
#
# Busybox w initramfsie nie ma /usr/share/udhcpc/default.script, wiec bez
# tego pliku udhcpc dostaje dzierzawe i NIC z nia nie robi. Uruchamiac:
#
#   udhcpc -i eth0 -s /mnt/scripts/udhcpc.sh -f -q -n -t 8 -T 3
#
# Zmienne ustawia udhcpc: interface, ip, mask (dlugosc prefiksu), subnet,
# broadcast, router, dns, domain, lease. $1 to zdarzenie.
#
# Bez polskich znakow celowo - czcionka konsoli to CP437.

[ -n "$1" ] || { echo "udhcpc.sh: uruchamiac przez udhcpc"; exit 1; }

RESOLV=/etc/resolv.conf

case "$1" in
	deconfig)
		ip addr flush dev "$interface" 2>/dev/null
		ip link set dev "$interface" up
		;;

	bound|renew)
		ip addr flush dev "$interface" 2>/dev/null
		ip addr add "$ip/$mask" broadcast "${broadcast:-+}" dev "$interface"
		if [ -n "$router" ]; then
			ip route del default 2>/dev/null
			for r in $router; do
				ip route add default via "$r" dev "$interface"
				break
			done
		fi
		: > "$RESOLV"
		[ -n "$domain" ] && echo "search $domain" >> "$RESOLV"
		for d in $dns; do
			echo "nameserver $d" >> "$RESOLV"
		done
		echo "udhcpc: $1: $interface -> $ip/$mask, brama ${router:-brak}, dns ${dns:-brak}, dzierzawa ${lease:-?} s"
		;;

	leasefail|nak)
		echo "udhcpc: $1 ${message:-}"
		;;
esac

exit 0
