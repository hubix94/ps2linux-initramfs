#!/bin/sh
#
# przelacz-modul.sh - podmien sterownik SMAP NA KONSOLI, z powrotem do
# sprawdzonej wersji, gdy nowa nie wstanie.
#
#   sh /mnt/scripts/przelacz-modul.sh                          # domyslnie v10
#   sh /mnt/scripts/przelacz-modul.sh /mnt/ps2-smap-v10.ko poll=2
#
# Uruchamiane lokalnie, nie przez SSH - wymiana sterownika zabiera interfejs,
# przez ktory idzie sesja, wiec zdalnie widac tylko zerwane polaczenie.
#
# WAZNE: sterownik do v6 wlacznie przy rmmod usypial PHY, a bez zegara z PHY
# reset EMAC3 nie konczy sie nigdy - stad -145 przy KAZDEJ podmianie, nie
# tylko po awarii. v7 budzi PHY sam (takze wtedy, gdy uspil go poprzednik),
# wiec od v7 podmiana bez restartu ma dzialac. Gdy mimo to zaden modul nie
# wstanie, zostaje restart konsoli - skrypt to rozpozna i powie wprost.
#
# 2026-09-06: v9 odpowiedzial. "PHY BMCR read failed with -145: MDIO is not
# answering" plus "mode0 20000000" znaczy, ze EMAC3 stoi w resecie, a MDIO
# idzie przez rejestr EMAC3 - wiec budzenie PHY PO nieudanym resecie nie mialo
# prawa zadzialac. v10 budzi PHY PRZED resetem i dlatego jest teraz domyslny.
#
# WERSJA 2 - zbiera logi sama. Wszystko laduje w logs-net/podmiana-N/ na
# pendrivie, tak samo jak ps2net2.sh zapisuje do logs-net/net-N. Nie trzeba
# juz przepisywac dmesg recznie i nie ma jak zapomniec o zrzucie przed
# restartem: zapis idzie na biezaco, z sync po kazdym pliku.
#
# Bez polskich znakow celowo - czcionka konsoli to CP437.

NOWY=${1:-/mnt/ps2-smap-v10.ko}
PARAM=${2:-}
ZAPASOWY=/mnt/ps2-smap.ko
IFACE=eth0
MODUL=ps2_smap
DHCP=/mnt/scripts/udhcpc.sh
DEST=/mnt/logs-net

[ -f "$NOWY" ] || { echo ">>> BLAD: brak $NOWY"; exit 1; }

# --- katalog wynikowy powstaje OD RAZU ---------------------------------------

mkdir -p "$DEST" 2>/dev/null
N=1
while [ -d "$DEST/podmiana-$N" ]; do
	N=$((N + 1))
done
RUN="$DEST/podmiana-$N"
mkdir -p "$RUN" || { echo ">>> BLAD: nie moge pisac na $DEST"; exit 1; }

POSTEP="$RUN/postep.txt"

krok() {
	echo "$*" >> "$POSTEP"
	sync
}

say() {
	echo ">>> $*"
	krok "$*"
}

grab() {
	out="$RUN/$1"
	shift
	printf '$ %s\n\n' "$*" > "$out"
	sync
	"$@" >> "$out" 2>&1
	printf '\n[exit %s]\n' "$?" >> "$out"
	sync
}

# Najwazniejszy plik przebiegu: linie sterownika, PHY i EMAC3 z calego dmesg.
# To w nim siedzi odpowiedz na pytanie, dlaczego reset EMAC3 nie przechodzi.
sterownik() {
	dmesg | grep -iE "ps2-smap|ps2_smap|BMCR|EMAC3|MDIO|phy|eth0" > "$RUN/$1" 2>&1
	sync
}

zrzut_koncowy() {
	grab dmesg-after.txt dmesg
	grab lsmod-after.txt lsmod
	grab interrupts-after.txt cat /proc/interrupts
	grab ip-link-after.txt ip link show
	sterownik dmesg-sterownik.txt
	sync
	echo
	say "logi: logs-net/podmiana-$N"
}

przerwane() {
	krok "PRZERWANE przez uzytkownika (Ctrl-C)"
	zrzut_koncowy
	exit 130
}
trap przerwane INT TERM

say "podmieniam na $NOWY ${PARAM:+($PARAM)}"
say "md5: $(md5sum "$NOWY" | cut -d' ' -f1)"
say "zapis do logs-net/podmiana-$N"

grab uname.txt uname -a
grab md5-ko.txt md5sum "$NOWY" "$ZAPASOWY"
grab dmesg-before.txt dmesg
grab lsmod-before.txt lsmod
grab interrupts-before.txt cat /proc/interrupts

# --- wyladowanie -------------------------------------------------------------

ip link set dev $IFACE down 2>/dev/null
if lsmod | grep -q "^$MODUL "; then
	krok "rmmod - START"
	if ! timeout 60 rmmod $MODUL; then
		say "rmmod nie przeszedl - modul utknal. Potrzebny restart konsoli."
		zrzut_koncowy
		exit 2
	fi
	krok "rmmod - wrocil"
fi
sleep 1
grab dmesg-po-rmmod.txt dmesg

# --- ladowanie ---------------------------------------------------------------

zaladuj() {
	printf '$ insmod %s %s\n\n' "$1" "$PARAM" > "$RUN/$2"
	sync
	timeout 60 insmod "$1" $PARAM >> "$RUN/$2" 2>&1
	rc=$?
	printf '\n[exit %s]\n' "$rc" >> "$RUN/$2"
	sync
	return $rc
}

krok "insmod nowego - START"
if zaladuj "$NOWY" insmod-nowy.txt; then
	say "$NOWY zaladowany"
	UZYTY=$NOWY
	krok "insmod nowego - OK"
elif [ "$NOWY" != "$ZAPASOWY" ] && zaladuj "$ZAPASOWY" insmod-zapasowy.txt; then
	say "NOWY NIE WSTAL - wrocilem na $ZAPASOWY"
	say "powod jest w dmesg; jesli to 'EMAC3 soft reset did not complete',"
	say "to kosc nie wychodzi z resetu i trzeba zrestartowac konsole"
	UZYTY=$ZAPASOWY
	krok "insmod nowego - ZAWIODL, wszedl zapasowy"
else
	say "ZADEN modul nie wstal - kosc nie wychodzi z resetu."
	say "Restart konsoli:  cd / ; umount /mnt ; poweroff -f"
	krok "insmod - ZADEN nie wstal"
	sterownik dmesg-sterownik.txt
	dmesg | tail -6
	zrzut_koncowy
	exit 3
fi

grab dmesg-po-insmod.txt dmesg
grab ip-link-po-insmod.txt ip link show
sterownik dmesg-sterownik-po-insmod.txt

# --- siec --------------------------------------------------------------------
#
# Nosna negocjuje sie 1-3 s. Bez tego udhcpc strzela w martwy interfejs
# i wraca z niczym - na tym wylozyla sie zdalna wymiana modulu.

ip link set dev $IFACE up
i=0
while [ $i -lt 20 ]; do
	[ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" = 1 ] && break
	sleep 1
	i=$((i + 1))
done
say "nosna po ${i}s: $(cat /sys/class/net/$IFACE/carrier 2>/dev/null)"
grab carrier.txt cat /sys/class/net/$IFACE/carrier

grab udhcpc.txt timeout 90 udhcpc -i $IFACE -s "$DHCP" -f -q -n -t 8 -T 3
IP=$(ip addr show $IFACE 2>/dev/null | grep "inet " | head -1 | sed 's/^ *inet \([^ ]*\).*/\1/')
grab ip-addr.txt ip addr show $IFACE
grab ip-route.txt ip route

echo
if [ -n "$IP" ]; then
	say "GOTOWE - adres $IP, dziala $UZYTY"
	say "SSH:  ssh -p 2222 root@${IP%/*}   (puste haslo)"
else
	say "modul wstal, ale adresu nie ma - sprobuj recznie:"
	say "    udhcpc -i $IFACE -s $DHCP -n -q"
fi

zrzut_koncowy
dmesg | grep -i "ps2-smap" | tail -4
