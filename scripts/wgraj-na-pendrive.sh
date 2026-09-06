#!/bin/bash
#
# wgraj-na-pendrive.sh - kopiuje pliki na nosnik startowy i zostawia na nim
# stempel czasu, z ktorego konsola ustawia zegar przy starcie.
#
# Konsola ma martwa bateria RTC i nie ma jeszcze NTP, wiec jedyna data, jaka
# zna po wlaczeniu, to ta, ktora sami jej podlozymy. Stempel wedruje do
# /mnt/time.txt na nosniku; czyta go initramfs/etc/init.d/set-clock.sh.
#
#   scripts/wgraj-na-pendrive.sh                     # sam odswieza stempel
#   scripts/wgraj-na-pendrive.sh linux/vmlinuz       # kopiuje i odswieza
#   scripts/wgraj-na-pendrive.sh work/smap/ps2-smap.ko:ps2-smap-v9.ko
#
# Zapis "zrodlo:nazwa-na-nosniku" pozwala zmienic nazwe przy kopiowaniu -
# przydaje sie przy sterownikach, bo /mnt/ps2-smap.ko ma zostac ta wersja,
# ktora jest sprawdzona, a nowa ma trafic obok, pod wlasna nazwa.
#
# Skrypt niczego nie kasuje.

set -e

NOSNIK=${NOSNIK:-/mnt/g}
LITERA=${LITERA:-G:}

if [ -z "$(ls -A "$NOSNIK" 2>/dev/null)" ]; then
	echo ">>> $NOSNIK pusty - montuje $LITERA (WSL nie robi tego sam)"
	# Punkt montowania potrafi zniknac miedzy sesjami WSL.
	[ -d "$NOSNIK" ] || sudo mkdir -p "$NOSNIK"
	sudo mount -t drvfs "$LITERA" "$NOSNIK"
fi

[ -n "$(ls -A "$NOSNIK" 2>/dev/null)" ] || { echo "BLAD: $NOSNIK nadal pusty"; exit 1; }

for arg in "$@"; do
	zrodlo=${arg%%:*}
	nazwa=${arg#*:}
	[ "$nazwa" = "$arg" ] && nazwa=$(basename "$zrodlo")

	[ -f "$zrodlo" ] || { echo "BLAD: brak $zrodlo"; exit 1; }

	cp "$zrodlo" "$NOSNIK/$nazwa"
	echo ">>> $zrodlo -> $NOSNIK/$nazwa  ($(md5sum "$zrodlo" | cut -d' ' -f1))"
done

# Stempel czasu: pierwsza linia to sekundy od epoki, druga to ten sam moment
# w formacie MMDDhhmmYYYY.ss w UTC - zapas na wypadek, gdyby busybox na
# konsoli nie przyjal skladni "date -s @sekundy".
{
	date +%s
	date -u +%m%d%H%M%Y.%S
} > "$NOSNIK/time.txt"

sync

echo ">>> stempel czasu: $(date '+%Y-%m-%d %H:%M:%S %Z') -> $NOSNIK/time.txt"
echo ">>> konsola ustawi ten czas przy najblizszym starcie (dokladnosc: minuty)"
