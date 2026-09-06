#!/bin/sh
#
# przeladuj-zdalnie.sh - przeladuj sterownik SMAP na zadanie z laptopa.
#
#   setsid sh /mnt/scripts/przeladuj-zdalnie.sh /tmp/ps2-smap-nowy.ko [param]
#
# URUCHAMIANY ODCZEPIONY OD SESJI SSH (setsid, w tle). Przeladowanie zabiera
# interfejs, ktorym idzie sesja, wiec skrypt przywiazany do niej dostalby
# SIGHUP w polowie roboty i zostawil konsole bez sterownika. To jest cala
# roznica miedzy dzialajaca zdalna wymiana a wyjazdem do telewizora.
#
# Gdy nowy modul nie wstanie, wraca na /mnt/ps2-smap.ko. Logi laduja same w
# /mnt/logs-net/wymiana-N/, wiec nie trzeba niczego przepisywac.
#
# Bez polskich znakow celowo - czcionka konsoli to CP437.

NOWY=${1:-/tmp/ps2-smap-nowy.ko}
PARAM=${2:-}
ZAPASOWY=/mnt/ps2-smap.ko
IFACE=eth0
MODUL=ps2_smap
DHCP=/mnt/scripts/udhcpc.sh
DEST=/mnt/logs-net

mkdir -p "$DEST" 2>/dev/null
N=1
while [ -d "$DEST/wymiana-$N" ]; do
	N=$((N + 1))
done
RUN="$DEST/wymiana-$N"
mkdir -p "$RUN" || exit 1

krok() {
	echo "$(date '+%H:%M:%S') $*" >> "$RUN/postep.txt"
	sync
}

krok "start, nowy=$NOWY param=${PARAM:-brak}"
md5sum "$NOWY" "$ZAPASOWY" > "$RUN/md5-ko.txt" 2>&1
dmesg > "$RUN/dmesg-before.txt" 2>&1
sync

# Odczekanie, zeby laptop zdazyl zamknac sesje SSH, ktora jedzie po eth0.
sleep 3

ip link set dev $IFACE down 2>/dev/null
if lsmod | grep -q "^$MODUL "; then
	if ! timeout 60 rmmod $MODUL; then
		krok "rmmod ZAWIODL - modul utknal, potrzebny restart konsoli"
		dmesg > "$RUN/dmesg-after.txt" 2>&1
		sync
		exit 2
	fi
	krok "rmmod ok"
fi
sleep 1

if timeout 60 insmod "$NOWY" $PARAM 2>> "$RUN/insmod.txt"; then
	krok "wszedl NOWY: $NOWY"
	UZYTY=$NOWY
elif timeout 60 insmod "$ZAPASOWY" 2>> "$RUN/insmod.txt"; then
	krok "nowy NIE WSTAL - wrocilem na $ZAPASOWY"
	UZYTY=$ZAPASOWY
else
	krok "ZADEN modul nie wstal - kosc nie wychodzi z resetu, potrzebny restart"
	dmesg > "$RUN/dmesg-after.txt" 2>&1
	sync
	exit 3
fi

ip link set dev $IFACE up
i=0
while [ $i -lt 20 ]; do
	[ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" = 1 ] && break
	sleep 1
	i=$((i + 1))
done
krok "nosna po ${i}s: $(cat /sys/class/net/$IFACE/carrier 2>/dev/null)"

timeout 90 udhcpc -i $IFACE -s "$DHCP" -f -q -n -t 10 -T 3 >> "$RUN/udhcpc.txt" 2>&1
IP=$(ip addr show $IFACE 2>/dev/null | grep "inet " | head -1 | sed 's/^ *inet \([^ ]*\).*/\1/')
krok "adres: ${IP:-BRAK}, dziala $UZYTY"

dmesg > "$RUN/dmesg-after.txt" 2>&1
dmesg | grep -iE "ps2-smap|BMCR|EMAC3|MDIO|phy|eth0" > "$RUN/dmesg-sterownik.txt" 2>&1
ip addr show $IFACE > "$RUN/ip-addr.txt" 2>&1
grep SPD /proc/interrupts > "$RUN/interrupts.txt" 2>&1
krok "koniec"
sync
