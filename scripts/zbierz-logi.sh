#!/bin/bash
#
# zbierz-logi.sh - sciaga z pendrive'a wszystko, czego jeszcze nie ma w repo.
#
#   scripts/zbierz-logi.sh              # do logs/<dzisiejsza-data>-scph30004/
#   scripts/zbierz-logi.sh 2026-09-06   # do wskazanego katalogu sesji
#
# Konsola zapisuje logi sama: ps2net2.sh do logs-net/net-N, przelacz-modul.sh
# do logs-net/podmiana-N, rcS do autolog/boot-N. Ten skrypt tylko przenosi to
# na laptopa - i pomija katalogi, ktore juz gdziekolwiek w logs/ sa, wiec
# mozna go puszczac po kazdym wyjezdzie bez zastanawiania sie, co nowego.
#
# Niczego nie kasuje ani na nosniku, ani w repo. Nie nadpisuje tego, co juz
# w repo jest - jesli katalog o tej nazwie istnieje, jest pomijany.

set -e

NOSNIK=${NOSNIK:-/mnt/g}
LITERA=${LITERA:-G:}
KORZEN=$(cd "$(dirname "$0")/.." && pwd)
SESJA=${1:-$(date +%F)}
CEL="$KORZEN/logs/$SESJA-scph30004"

if [ -z "$(ls -A "$NOSNIK" 2>/dev/null)" ]; then
	echo ">>> $NOSNIK pusty - montuje $LITERA (WSL nie robi tego sam)"
	# Punkt montowania potrafi zniknac miedzy sesjami WSL.
	[ -d "$NOSNIK" ] || sudo mkdir -p "$NOSNIK"
	sudo mount -t drvfs "$LITERA" "$NOSNIK"
fi

[ -n "$(ls -A "$NOSNIK" 2>/dev/null)" ] || { echo "BLAD: $NOSNIK nadal pusty"; exit 1; }

# Katalog uznajemy za znany, gdy wystepuje w DOWOLNEJ sesji w logs/ - numery
# net-N i boot-N sa ciagle przez wiele wyjazdow, wiec sama nazwa wystarcza.
znany() {
	local nazwa=$1
	find "$KORZEN/logs" -maxdepth 3 -type d -name "$nazwa" 2>/dev/null | grep -q .
}

nowe=0
skopiuj_grupe() {
	local zrodlo=$1 podkatalog=$2
	[ -d "$zrodlo" ] || return 0

	for d in "$zrodlo"/*/; do
		[ -d "$d" ] || continue
		nazwa=$(basename "$d")
		if znany "$nazwa"; then
			continue
		fi
		mkdir -p "$CEL/$podkatalog"
		cp -r "$d" "$CEL/$podkatalog/"
		echo ">>> nowy: $podkatalog/$nazwa"
		nowe=$((nowe + 1))
	done
}

skopiuj_grupe "$NOSNIK/logs-net" logs-net
skopiuj_grupe "$NOSNIK/autolog" autolog

# Pliki zbiorcze nadpisujemy zawsze - to dzienniki dopisywane, wiec swiezsza
# kopia zawiera wszystko, co miala poprzednia.
for f in logs-net/watchdog.log time-log.txt time.txt czas-log.txt czas.txt; do
	if [ -f "$NOSNIK/$f" ]; then
		mkdir -p "$CEL/$(dirname "$f")"
		cp "$NOSNIK/$f" "$CEL/$f"
		echo ">>> odswiezone: $f"
	fi
done

echo
if [ "$nowe" -gt 0 ]; then
	echo ">>> $nowe nowych katalogow w logs/$SESJA-scph30004"
else
	echo ">>> nic nowego na nosniku - w repo jest juz wszystko"
fi
du -sh "$CEL" 2>/dev/null || true
