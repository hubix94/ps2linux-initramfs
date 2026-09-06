#!/bin/sh
#
# ps2net-watchdog.sh - pilnuje sieci na eth0 i probuje ja odzyskac po awarii.
#
#   sh /mnt/scripts/ps2net-watchdog.sh &        # w tle, zalecane
#   sh /mnt/scripts/ps2net-watchdog.sh -1       # jeden przebieg naprawy i koniec
#
# PO CO TO JEST. Sterownik ps2-smap do wersji 3 wlacznie nadpisuje rejestr
# maski przerwan kosci SPEED (offset 0x2a), ktorym zarzadza IOP. Przy ciaglym
# transferze dochodzi do wyscigu i odmaskowanie przepada. Skutek: przerwania
# RXEND/TXEND stoja zapalone w rejestrze stanu, nikt ich nie obsluguje,
# kolejka nadawcza staje, a konsola dziala dalej jak gdyby nigdy nic.
# Rozpoznanie po sladzie: "tx timeout" w dmesg i zamrozony licznik
# "IOP SPD TXEND" w /proc/interrupts.
#
# UWAGA DO PRZELADOWANIA MODULU. Sterownik do wersji 6 wlacznie przy kazdym
# rmmod zostawial PHY w stanie power-down (phy_disconnect -> genphy_suspend),
# a reset EMAC3 bez zegara z PHY nigdy sie nie konczy - insmod odbijal sie
# z "EMAC3 soft reset did not complete", blad -145 (ETIMEDOUT). Dlatego proby
# 2 i 3 tego skryptu z tamtymi wersjami ZAWSZE zawodzily. Od v7 sterownik
# budzi PHY sam, i dopiero wtedy te proby maja sens. Jesli mimo to zaden
# modul nie wstaje - zostaje restart konsoli; skrypt to powie wprost.
#
# Kazda proba naprawy zapisuje PELNA diagnostyke na pendrive PRZED tym, jak
# cokolwiek ruszy - inaczej slad awarii przepada razem z awaria.
#
# Bez polskich znakow celowo - czcionka konsoli to CP437.

PENDRIVE=/mnt
IFACE=eth0
MODUL=ps2_smap
KO=$PENDRIVE/ps2-smap.ko
DHCP_SCRIPT=$PENDRIVE/scripts/udhcpc.sh
INTERWAL=20		# co ile sekund sprawdzac lacznosc
PROG_BLEDOW=2		# ile nieudanych sprawdzen z rzedu uznajemy za awarie

JEDEN_RAZ=0
[ "${1:-}" = "-1" ] && JEDEN_RAZ=1

say() { echo ">>> watchdog: $*"; }

# --- katalog na slady -------------------------------------------------------

DEST=$PENDRIVE/logs-net
mkdir -p "$DEST" 2>/dev/null
LOG=$DEST/watchdog.log

zapisz() {
	echo "[$(cat /proc/uptime | cut -d. -f1)s] $*" >> "$LOG"
	sync
}

# --- ustalenie, do czego pingowac ------------------------------------------
#
# Brama z tablicy trasowania. Gdyby jej nie bylo (np. awaria przyszla, zanim
# udhcpc dokonczyl), bierzemy adres serwera DHCP, a w ostatecznosci 1.1.1.1.

ustal_cel() {
	CEL=$(ip route 2>/dev/null | grep "^default" | head -1 | sed 's/^default via \([^ ]*\).*/\1/')
	[ -z "$CEL" ] && CEL=$(sed -n 's/^nameserver //p' /etc/resolv.conf 2>/dev/null | head -1)
	[ -z "$CEL" ] && CEL=1.1.1.1
}

# --- sprawdzenie lacznosci --------------------------------------------------
#
# Sam ping nie wystarcza jako dowod: gdy padnie brama albo ktos wyjmie kabel,
# to nie jest awaria sterownika i przeladowanie modulu niczego nie naprawi.
# Dlatego patrzymy takze na nosna i na slad "tx timeout" w dmesg.

sprawdz() {
	[ -d /sys/class/net/$IFACE ] || return 1
	ping -c 1 -W 3 "$CEL" > /dev/null 2>&1 && return 0
	return 1
}

nosna() {
	cat /sys/class/net/$IFACE/carrier 2>/dev/null || echo 0
}

# Czy interfejs w ogole istnieje. To NIE to samo, co zgaszona nosna:
# brak katalogu w /sys znaczy, ze sterownik nie jest zaladowany, i wtedy
# przeladowanie modulu jest dokladnie tym, czego trzeba. Wczesniejsza wersja
# tego skryptu mylila oba przypadki i przy znikniętym eth0 pisala w kolko
# "brak nosnej - czekam", zamiast probowac naprawy.
interfejs_istnieje() {
	[ -d /sys/class/net/$IFACE ]
}

objaw_sterownika() {
	# Slad awarii maski: watchdog jadra zaczyna zglaszac zatrzymana kolejke.
	dmesg | tail -40 | grep -q "tx timeout\|transmit queue 0 timed out"
}

# --- diagnostyka przed naprawa ---------------------------------------------

zbierz_slad() {
	kat="$DEST/awaria-$1"
	mkdir -p "$kat" 2>/dev/null || return 1
	dmesg > "$kat/dmesg.txt" 2>&1
	cat /proc/interrupts > "$kat/interrupts.txt" 2>&1
	# busybox ip nie zna -s, liczniki sa w /proc/net/dev nizej
	ip link show $IFACE > "$kat/ip-link.txt" 2>&1
	ip link show >> "$kat/ip-link.txt" 2>&1
	dmesg | tail -40 > "$kat/dmesg-ogon.txt" 2>&1
	ip addr show $IFACE > "$kat/ip-addr.txt" 2>&1
	ip route > "$kat/ip-route.txt" 2>&1
	cat /proc/net/dev > "$kat/net-dev.txt" 2>&1
	lsmod > "$kat/lsmod.txt" 2>&1
	cat /proc/meminfo > "$kat/meminfo.txt" 2>&1
	if interfejs_istnieje; then
		for f in /sys/class/net/$IFACE/statistics/*; do
			echo "$(basename $f) = $(cat $f 2>/dev/null)"
		done > "$kat/statistics.txt" 2>&1
	else
		echo "interfejsu $IFACE nie ma w /sys" > "$kat/statistics.txt"
	fi
	echo "nosna: $(nosna)" >> "$kat/statistics.txt"
	sync
	say "slad zapisany w logs-net/awaria-$1"
	zapisz "slad w awaria-$1"
}

# --- adres z DHCP -----------------------------------------------------------

wez_adres() {
	if [ -f "$DHCP_SCRIPT" ]; then
		timeout 60 udhcpc -i $IFACE -s "$DHCP_SCRIPT" -f -q -n -t 6 -T 3 \
			> /dev/null 2>&1
	else
		timeout 60 udhcpc -i $IFACE -f -q -n -t 6 -T 3 > /dev/null 2>&1
	fi
	ustal_cel
}

# --- kroki naprawcze, od najlzejszego --------------------------------------

# 1. Sama warstwa IP. Pomaga, gdy zgubila sie tylko dzierzawa DHCP,
#    a sterownik jest caly.
naprawa_1_adres() {
	say "proba 1/4: podniesienie interfejsu i nowy adres"
	zapisz "proba 1: link + dhcp"
	ip link set dev $IFACE down 2>/dev/null
	sleep 1
	ip link set dev $IFACE up 2>/dev/null
	sleep 3
	wez_adres
	sprawdz
}

# 2. Przeladowanie modulu w tej samej postaci, w jakiej byl.
naprawa_2_modul() {
	say "proba 2/4: przeladowanie sterownika"
	zapisz "proba 2: rmmod + insmod"
	[ -f "$KO" ] || { say "brak $KO - pomijam"; return 1; }
	ip link set dev $IFACE down 2>/dev/null
	# Gdy modulu nie ma wcale, rmmod slusznie zawodzi i to nie jest blad -
	# przechodzimy prosto do zaladowania.
	if lsmod | grep -q "^$MODUL "; then
		if ! timeout 60 rmmod $MODUL 2>/dev/null; then
			say "rmmod nie przeszedl - modul utknal, dalsze proby nie maja sensu"
			zapisz "proba 2: rmmod ZAWIODL"
			return 2
		fi
	fi
	sleep 1
	if ! timeout 60 insmod "$KO" 2>/dev/null; then
		say "insmod odrzucil modul - patrz dmesg"
		zapisz "proba 2: insmod ZAWIODL"
		return 1
	fi
	sleep 2
	ip link set dev $IFACE up 2>/dev/null
	sleep 3
	wez_adres
	sprawdz
}

# 3. To samo, ale sterownik w trybie czystego odpytywania. Ten tryb NIE
#    korzysta z przerwan, wiec dziala takze wtedy, gdy maska przerwan
#    kosci jest juz nie do odzyskania. Wolniejszy, ale zywy.
naprawa_3_odpytywanie() {
	say "proba 3/4: sterownik w trybie odpytywania (poll=2)"
	zapisz "proba 3: insmod poll=2"
	[ -f "$KO" ] || return 1
	ip link set dev $IFACE down 2>/dev/null
	lsmod | grep -q "^$MODUL " && timeout 60 rmmod $MODUL 2>/dev/null
	sleep 1
	if ! timeout 60 insmod "$KO" poll=2 2>/dev/null; then
		say "insmod poll=2 odrzucony"
		zapisz "proba 3: insmod poll=2 ZAWIODL"
		return 1
	fi
	sleep 2
	ip link set dev $IFACE up 2>/dev/null
	sleep 3
	wez_adres
	sprawdz
}

# 4. Nic wiecej z przestrzeni uzytkownika nie zrobimy. Miekki reset EMAC3
#    po tej awarii bywa nieodwracalny i wtedy kosc wraca do zycia dopiero
#    po odcieciu zasilania zatoki, czyli po restarcie konsoli.
naprawa_4_poddaj_sie() {
	say ""
	say "NIE UDALO SIE ODZYSKAC SIECI Z POZIOMU SYSTEMU."
	say "Jesli w dmesg jest 'EMAC3 soft reset did not complete' albo"
	say "'probe of ps2-smap failed with error -145', to kosc SPEED nie"
	say "wychodzi z resetu i pomoze dopiero restart konsoli:"
	say "    cd / ; umount $PENDRIVE ; poweroff -f"
	say ""
	zapisz "wszystkie proby wyczerpane - potrzebny restart"
}

# --- pelna sekwencja naprawcza ---------------------------------------------

napraw() {
	znacznik=$(cat /proc/uptime | cut -d. -f1)
	say "AWARIA SIECI wykryta (cel $CEL, nosna $(nosna))"
	zapisz "AWARIA: cel $CEL nosna $(nosna)"
	if objaw_sterownika; then
		say "w dmesg jest 'tx timeout' - to wyglada na zgubiona maske przerwan"
		zapisz "objaw: tx timeout w dmesg"
	fi

	zbierz_slad "$znacznik"

	naprawa_1_adres && { say "ODZYSKANE po probie 1"; zapisz "OK po probie 1"; return 0; }

	naprawa_2_modul
	wynik=$?
	[ $wynik -eq 0 ] && { say "ODZYSKANE po probie 2"; zapisz "OK po probie 2"; return 0; }
	if [ $wynik -eq 2 ]; then
		naprawa_4_poddaj_sie
		return 1
	fi

	naprawa_3_odpytywanie && {
		say "ODZYSKANE po probie 3 - sterownik chodzi na ODPYTYWANIU,"
		say "czyli bez przerwan. Wolniej, ale stabilnie."
		zapisz "OK po probie 3 (poll=2)"
		return 0
	}

	naprawa_4_poddaj_sie
	return 1
}

# --- glowna petla -----------------------------------------------------------

ustal_cel
say "start, cel $CEL, sprawdzanie co ${INTERWAL}s"
zapisz "watchdog start, cel $CEL"

if [ "$JEDEN_RAZ" = "1" ]; then
	napraw
	exit $?
fi

bledy=0
while true; do
	if sprawdz; then
		if [ "$bledy" -gt 0 ]; then
			say "lacznosc wrocila sama"
			zapisz "lacznosc wrocila sama po $bledy nieudanych sprawdzeniach"
		fi
		bledy=0
	else
		bledy=$((bledy + 1))
		say "brak lacznosci ($bledy/$PROG_BLEDOW)"
		if [ "$bledy" -ge "$PROG_BLEDOW" ]; then
			if ! interfejs_istnieje; then
				say "nie ma $IFACE w /sys - sterownik nie jest zaladowany."
				zapisz "brak interfejsu - probuje zaladowac modul"
				napraw || {
					say "koncze - dalsze proby nie maja sensu"
					exit 1
				}
				bledy=0
				ustal_cel
			elif [ "$(nosna)" != "1" ]; then
				say "nosna zgaszona - to kabel albo przelacznik, nie sterownik."
				say "Nie ruszam modulu. Czekam."
				zapisz "brak nosnej - czekam, nie naprawiam"
				bledy=0
			else
				napraw || {
					say "koncze - dalsze proby nie maja sensu"
					exit 1
				}
				bledy=0
				ustal_cel
			fi
		fi
	fi
	sleep "$INTERWAL"
done
