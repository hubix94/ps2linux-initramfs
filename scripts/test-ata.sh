#!/bin/sh
#
# test-ata.sh - czy pata_ps2 i sterownik SMAP moga zyc razem w jednej zatoce.
#
#   setsid sh /mnt/scripts/test-ata.sh
#
# Odpowiedz na pytanie 3 od frno7 z PR #94. pata_ps2 siega po zatoke przez
# iopmod/module/dev9.c, a nasz uklad wlacza ja przez jadrowy iop-dev9 - dwa
# wlasciciele tego samego sprzetu.
#
# URUCHAMIANY ODCZEPIONY OD SESJI SSH. Jesli test zabije siec, sesja padnie,
# a skrypt ma dokonczyc i zostawic slad na nosniku - inaczej wynik ginie.
#
# Sam sie ratuje: gdy po zaladowaniu pata_ps2 brama przestaje odpowiadac,
# wyladowuje go i sprawdza ponownie. To rozdziela "zatoka nie znosi dwoch
# wlascicieli" od "cos sie zepsulo na stale".
#
# Bez polskich znakow celowo - czcionka konsoli to CP437.

DEST=/mnt/logs-net
BRAMA=192.168.1.1

mkdir -p "$DEST" 2>/dev/null
N=1
while [ -d "$DEST/ata-$N" ]; do
	N=$((N + 1))
done
RUN="$DEST/ata-$N"
mkdir -p "$RUN" || exit 1

krok() {
	echo "$(date '+%H:%M:%S') $*" >> "$RUN/postep.txt"
	sync
}

zbierz() {
	dmesg > "$RUN/dmesg-$1.txt" 2>&1
	lsmod > "$RUN/lsmod-$1.txt" 2>&1
	cat /proc/interrupts > "$RUN/interrupts-$1.txt" 2>&1
	ip addr show eth0 > "$RUN/ip-addr-$1.txt" 2>&1
	sync
}

siec_zyje() {
	ping -c 3 -W 2 "$BRAMA" > "$RUN/ping-$1.txt" 2>&1
}

krok "start"
zbierz before
if siec_zyje before; then
	krok "przed: siec dziala"
else
	krok "przed: BRAMA NIE ODPOWIADA - test bez sensu, koncze"
	exit 1
fi

sleep 2

krok "modprobe pata_ps2 - START"
timeout 90 modprobe pata_ps2 > "$RUN/modprobe.txt" 2>&1
krok "modprobe pata_ps2 - wrocil z kodem $?"

sleep 5
zbierz after
dmesg | grep -iE "ata|dev9|scsi|speed" | tail -30 > "$RUN/dmesg-ata.txt" 2>&1
sync

if siec_zyje after; then
	krok "PO: siec NADAL DZIALA - pata_ps2 i SMAP wspolistnieja"
	krok "koniec, pata_ps2 zostaje zaladowany do ogledzin"
	zbierz koncowy
	exit 0
fi

krok "PO: BRAMA MILCZY - probuje wycofac pata_ps2"
timeout 60 rmmod pata_ps2 >> "$RUN/rmmod.txt" 2>&1
krok "rmmod pata_ps2 wrocil z kodem $?"
sleep 5

if siec_zyje po-rmmod; then
	krok "siec WROCILA po wyladowaniu pata_ps2 - konflikt jest odwracalny"
else
	krok "siec NADAL MARTWA - probuje przeladowac sterownik SMAP"
	ip link set dev eth0 down 2>/dev/null
	timeout 60 rmmod ps2_smap >> "$RUN/rmmod.txt" 2>&1
	sleep 1
	timeout 60 insmod /mnt/ps2-smap.ko >> "$RUN/insmod.txt" 2>&1
	ip link set dev eth0 up
	i=0
	while [ $i -lt 20 ]; do
		[ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = 1 ] && break
		sleep 1
		i=$((i + 1))
	done
	timeout 90 udhcpc -i eth0 -s /mnt/scripts/udhcpc.sh -f -q -n -t 10 -T 3 >> "$RUN/udhcpc.txt" 2>&1
	if siec_zyje po-przeladowaniu; then
		krok "siec wrocila po przeladowaniu SMAP-a"
	else
		krok "SIEC NIE WROCILA - potrzebny restart konsoli z reki"
	fi
fi

zbierz koncowy
krok "koniec"
