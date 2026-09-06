#!/bin/sh
#
# ps2net2.sh - zaladuj sterownik SMAP, wez adres z DHCP, sprawdz lacznosc.
#
#   sh /mnt/scripts/ps2net2.sh          # kabel ethernet W GNIEZDZIE
#
# Wymaga jadra, w ktorym iop-dev9 wlacza zatoke przy starcie (galaz
# ps2-dev9-power-up, ELF vmlinuz-pal-dev9-*.elf) - sterownik sam to
# sprawdza i odmawia zaladowania, gdy zatoka jest wylaczona.
#
# TRYB PRZERWAN. Sterownik domyslnie chodzi na przerwaniach, ale ma
# watchdoga: gdy deskryptor sie domknie, a nie przyszlo ANI JEDNO
# przerwanie, przelacza sie na odpytywanie i mowi o tym w dmesg. Nie
# trzeba nic podawac. Wymuszenie recznie, gdyby bylo potrzebne:
#
#   insmod /mnt/ps2-smap.ko poll=2      # tylko odpytywanie, bez przerwan
#   insmod /mnt/ps2-smap.ko poll=0      # tylko przerwania, bez ratunku
#
# WERSJA 3. Kroki:
# PORT SSH TO 2222, NIE 22. Na porcie 22 siedzi inetd (inittab uruchamia go
# przy starcie), a jego wpis w /etc/inetd.conf kieruje polaczenia na
# "dropbear -i -s -g" - bez kluczy hosta, z zakazem logowania haslem i bez
# /root/.ssh/authorized_keys. Taki dropbear konczy sie, zanim wysle powitanie,
# wiec z zewnatrz widac tylko zerwane polaczenie. Wersja 2 tego skryptu
# sprawdzala jedynie, czy COKOLWIEK nasluchuje na 22, i przez to melduje
# sukces, choc jej wlasny dropbear nie mogl zajac portu i konczyl prace.
#
# Po wywrotce jadra (Oops) modul zostaje na zawsze w stanie "Loading" -
# kolejny insmod w tej samej sesji tylko zawisa i marnuje przebieg. Skrypt
# to teraz wykrywa i mowi wprost, ze trzeba zrestartowac konsole.
#
#   1. stan wyjsciowy (dmesg, lsmod, przerwania)
#   2. insmod ps2-smap.ko -> ma powstac eth0
#   3. ip link set eth0 up, czekanie na link (autonegocjacja 1-3 s)
#   4. udhcpc z naszym skryptem -> adres, brama, DNS
#   5. ping do bramy i do 1.1.1.1, liczniki
#   6. dropbear (SSH) NA PORCIE 2222 - root bez hasla
#   7. watchdog sieci w tle (ps2net-watchdog.sh)
#
# Zapis na biezaco na pendrive, jak w ps2net1.sh. Pendrive zostaje
# ZAMONTOWANY na koncu, bo dropbear ma dzialac dalej; wylaczanie:
#   cd / ; umount /mnt ; poweroff -f
#
# Jesli insmod nie wraca przez ponad minute - IOP stanal, wylacz konsole
# przyciskiem. postep.txt mowi, ktory krok to zrobil.
#
# Bez polskich znakow celowo - czcionka konsoli to CP437.

PENDRIVE=/mnt
MODUL=ps2-smap
IFACE=eth0
DHCP_SCRIPT=$PENDRIVE/scripts/udhcpc.sh
SSH_PORT=2222

say() { echo ">>> $*"; }

# --- pendrive: montuje rcS w tle, czekamy na niego -----------------------------

if ! grep -q " $PENDRIVE " /proc/mounts; then
	echo "czekam, az rcS zamontuje pendrive..."
	i=0
	while [ "$i" -lt 60 ]; do
		grep -q " $PENDRIVE " /proc/mounts && break
		[ -f /tmp/usb-failed ] && break
		sleep 1
		i=$((i + 1))
	done
fi

if ! grep -q " $PENDRIVE " /proc/mounts; then
	echo "BLAD: $PENDRIVE nie jest zamontowany, a rcS nie dal rady."
	echo "Sprobuj recznie:  mount -t vfat /dev/sda1 $PENDRIVE"
	exit 1
fi

KO="$PENDRIVE/$MODUL.ko"
if [ ! -f "$KO" ]; then
	echo "BLAD: brak $KO"
	exit 1
fi
if [ ! -f "$DHCP_SCRIPT" ]; then
	echo "BLAD: brak $DHCP_SCRIPT - bez niego udhcpc nie ustawi adresu"
	exit 1
fi

# --- katalog wynikowy powstaje OD RAZU ---------------------------------------

DEST="$PENDRIVE/logs-net"
mkdir -p "$DEST" 2>/dev/null
N=1
while [ -d "$DEST/net-$N" ]; do
	N=$((N + 1))
done
RUN="$DEST/net-$N"
mkdir -p "$RUN" || { echo "BLAD: nie moge pisac na $PENDRIVE"; exit 1; }

POSTEP="$RUN/postep.txt"

krok() {
	echo "$*" >> "$POSTEP"
	sync
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

przerwane() {
	krok "PRZERWANE przez uzytkownika (Ctrl-C)"
	dmesg > "$RUN/dmesg-przerwanie.txt" 2>&1
	sync
	echo
	say "przerwane - to, co zdazylo sie zebrac, jest w logs-net/net-$N"
	exit 130
}
trap przerwane INT TERM

krok "start, sterownik v3"
say "ps2net2 v3 - zapis do logs-net/net-$N"

# --- 1. stan wyjsciowy -------------------------------------------------------

say "1/7  stan wyjsciowy"
krok "1: stan wyjsciowy"
grab uname.txt uname -a
grab md5-ko.txt md5sum "$KO"
grab dmesg-before.txt dmesg
grab lsmod-before.txt lsmod
grab interrupts-before.txt cat /proc/interrupts
grab ip-link-before.txt ip link show
dmesg | grep -i "dev9\|rev-test" > "$RUN/dmesg-dev9.txt"
sync

if ! grep -q "Expansion device power on" "$RUN/dmesg-dev9.txt"; then
	say "UWAGA: w dmesg nie ma 'dev9: Expansion device power on' - to nie jest"
	say "       jadro z poprawka DEV9? Sterownik pewnie odmowi. Probuje mimo to."
fi

# --- 2. sterownik ------------------------------------------------------------

# Ile linii ma dmesg PRZED insmodem - zeby szukac wywrotki tylko wsrod tego,
# co dopisal ten insmod, a nie w calym logu rozruchu.
DMESG_PRZED=$(dmesg | wc -l)

say "2/7  insmod $MODUL.ko"
say "     (jesli to nie wroci przez ponad minute - IOP stanal; wylacz konsole przyciskiem)"
krok "2: insmod - START"
grab insmod.txt timeout 120 insmod "$KO"
krok "2: insmod - wrocil"
sleep 1
dmesg | grep -i "$MODUL\|smap\|mdio\|phy\|eth0" > "$RUN/dmesg-sterownik.txt" 2>&1
grab dmesg-po-insmod.txt dmesg
grab lsmod-po-insmod.txt lsmod
grab sys-class-net.txt ls -l /sys/class/net
sync

echo
echo "----------------------------------------------------------------"
cat "$RUN/dmesg-sterownik.txt"
echo "----------------------------------------------------------------"

# Wywrotka jadra w insmodzie: modul zostaje w stanie "Loading" i nastepny
# insmod juz nie wroci, wiec ponawianie bez restartu nie ma sensu.
dmesg | tail -n +$((DMESG_PRZED + 1)) \
	| grep -i "Oops\|BUG:\|Unable to handle kernel" > "$RUN/oops.txt" 2>&1
if [ -s "$RUN/oops.txt" ]; then
	echo
	say "WYWROTKA JADRA przy insmod - slad w logs-net/net-$N/oops.txt"
	say "Nie ponawiaj w tej sesji: modul utknal w stanie Loading i kolejny"
	say "insmod zawisnie. Wylacz konsole i uruchom ponownie."
	krok "2: OOPS przy insmod - koniec"
	head -4 "$RUN/oops.txt"
	exit 1
fi

if ! ip link show "$IFACE" > /dev/null 2>&1; then
	say "BLAD: nie ma $IFACE. Koniec. Wszystko jest w logs-net/net-$N"
	krok "2: BRAK $IFACE - koniec"
	exit 1
fi
grab ip-link-po-insmod.txt ip link show "$IFACE"

# --- 3. link -----------------------------------------------------------------

say "3/7  ip link set $IFACE up, czekam na link"
krok "3: link up - START"
grab ip-link-set-up.txt ip link set dev "$IFACE" up
i=0
while [ "$i" -lt 20 ]; do
	c=$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)
	[ "$c" = "1" ] && break
	sleep 1
	i=$((i + 1))
done
echo "carrier po $i s: $(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" > "$RUN/carrier.txt"
grab ip-link-po-up.txt ip link show "$IFACE"
grab interrupts-po-up.txt cat /proc/interrupts
dmesg | grep -i "$MODUL\|link" | tail -20 > "$RUN/dmesg-link.txt"
sync
krok "3: link - carrier=$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)"
cat "$RUN/carrier.txt"
cat "$RUN/dmesg-link.txt" | tail -5

if [ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" != "1" ]; then
	say "UWAGA: brak linku po 20 s. Kabel wpiety? Probuje DHCP mimo to."
fi

# --- 4. DHCP -----------------------------------------------------------------

say "4/7  udhcpc (do 8 prob po 3 s)"
krok "4: udhcpc - START"
grab udhcpc.txt timeout 90 udhcpc -i "$IFACE" -s "$DHCP_SCRIPT" -f -q -n -t 8 -T 3
krok "4: udhcpc - wrocil"
grab ip-addr.txt ip addr show "$IFACE"
grab ip-route.txt ip route
grab resolv.txt cat /etc/resolv.conf
sync

IP=$(ip addr show "$IFACE" 2>/dev/null | grep "inet " | head -1 | sed 's/^ *inet \([^ ]*\).*/\1/')
GW=$(ip route 2>/dev/null | grep "^default" | head -1 | sed 's/^default via \([^ ]*\).*/\1/')
echo "${IP:-brak}" > "$RUN/adres-ip.txt"
sync

echo
echo "================================================================"
if [ -n "$IP" ]; then
	echo "  ADRES IP KONSOLI: $IP   (brama: ${GW:-brak})"
	krok "4: ADRES $IP brama ${GW:-brak}"
else
	echo "  BRAK ADRESU - udhcpc nie dostal dzierzawy"
	krok "4: BRAK ADRESU"
fi
echo "================================================================"
echo

# --- 5. lacznosc -------------------------------------------------------------

say "5/7  ping"
krok "5: ping - START"
if [ -n "$GW" ]; then
	grab ping-brama.txt ping -c 4 -W 2 "$GW"
	tail -3 "$RUN/ping-brama.txt"
fi
grab ping-1111.txt ping -c 3 -W 2 1.1.1.1
tail -3 "$RUN/ping-1111.txt"
grab net-dev.txt cat /proc/net/dev
grab interrupts-po-ping.txt cat /proc/interrupts
grab dmesg-po-ping.txt dmesg

# Ktory tryb naprawde chodzil - to jest osobny wynik tego wyjazdu,
# niezalezny od tego, czy adres przyszedl.
dmesg | grep -i "ps2-smap\|smap:" | grep -i "polling\|relay\|interrupt" \
	> "$RUN/tryb-przerwan.txt" 2>&1
grep -i "IOP SPD" /proc/interrupts >> "$RUN/tryb-przerwan.txt" 2>&1
sync

echo
if grep -q "switching to polling" "$RUN/tryb-przerwan.txt" 2>/dev/null; then
	say "UWAGA: przerwania SPEED NIE dochodza - sterownik przeszedl na odpytywanie."
	say "       To osobne znalezisko: sciezka danych dziala, relay IOP nie."
	krok "5: przerwania martwe, chodzi odpytywanie"
else
	say "przerwania dzialaja (brak przelaczenia na odpytywanie)"
	krok "5: przerwania dzialaja"
fi
cat "$RUN/tryb-przerwan.txt"
krok "5: ping - koniec"

# --- 6. SSH ------------------------------------------------------------------

say "6/7  dropbear (SSH)"
krok "6: dropbear - START"
DB=""
for f in /usr/sbin/dropbear /usr/bin/dropbear /sbin/dropbear; do
	[ -x "$f" ] && { DB="$f"; break; }
done
if [ -z "$DB" ] && [ -x /usr/bin/dropbearmulti ]; then
	DB="/usr/bin/dropbearmulti dropbear"
fi
if [ -n "$DB" ] && [ -n "$IP" ]; then
	mkdir -p /etc/dropbear
	# -R: wygeneruj klucze hosta przy pierwszym polaczeniu (ed25519 liczy sie
	#     natychmiast nawet na 294 MHz)
	# -B: pozwol na logowanie bez hasla (root ma puste haslo w /etc/passwd)
	# -E: log na stderr
	# -p: port 2222, bo 22 nalezy do inetd - patrz naglowek
	#
	# Log idzie do /tmp, NIE na pendrive: dropbear zyje po zakonczeniu
	# skryptu i trzymalby otwarty plik na vfat, ktory potem sie odmontowuje.
	$DB -R -B -E -p "$SSH_PORT" 2> /tmp/dropbear.log &
	sleep 2
	grab netstat.txt netstat -ltn
	cp /tmp/dropbear.log "$RUN/dropbear.txt" 2>/dev/null
	if grep -q ":$SSH_PORT " "$RUN/netstat.txt"; then
		say "dropbear nasluchuje na $SSH_PORT - z komputera:"
		say "    ssh -p $SSH_PORT root@${IP%/*}     (puste haslo)"
		krok "6: dropbear nasluchuje na $SSH_PORT"
	else
		say "dropbear nie nasluchuje - patrz logs-net/net-$N/dropbear.txt"
		krok "6: dropbear NIE nasluchuje"
	fi
else
	say "pomijam dropbear (brak binarki albo adresu)"
	krok "6: dropbear pominiety"
fi

# --- 7. watchdog sieci -------------------------------------------------------
#
# Zostaje w tle i probuje odzyskac siec, gdy ta padnie - patrz naglowek
# ps2net-watchdog.sh. Startuje tylko wtedy, gdy adres w ogole przyszedl,
# bo inaczej nie ma czego pilnowac.

WATCHDOG=$PENDRIVE/scripts/ps2net-watchdog.sh
if [ -n "$IP" ] && [ -f "$WATCHDOG" ]; then
	say "7/7  watchdog sieci w tle"
	sh "$WATCHDOG" > /tmp/watchdog.out 2>&1 &
	krok "7: watchdog wystartowal"
	say "     log: logs-net/watchdog.log, slady awarii: logs-net/awaria-*"
else
	krok "7: watchdog pominiety"
fi

grab dmesg-after.txt dmesg
grab interrupts-after.txt cat /proc/interrupts
krok "KONIEC - wszystkie kroki przeszly"
sync

echo
say "zapisane w logs-net/net-$N; pendrive ZOSTAJE zamontowany (dropbear dziala)"
say "kiedy skonczysz:  cd / ; umount $PENDRIVE ; poweroff -f"
[ -n "$IP" ] && say "ADRES IP KONSOLI: $IP"
[ -n "$IP" ] && say "SSH:  ssh -p $SSH_PORT root@${IP%/*}   (puste haslo)"
