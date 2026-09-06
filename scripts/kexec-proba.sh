#!/bin/sh
#
# kexec-proba.sh - jedna proba kexec, ze sladem zapisanym PRZED skokiem.
#
#   sh /mnt/scripts/kexec-proba.sh                       # laduje i skacze
#   sh /mnt/scripts/kexec-proba.sh /mnt/inny.elf         # inny obraz docelowy
#   SKOK=nie sh /mnt/scripts/kexec-proba.sh              # tylko zaladuj
#
# Po skoku stare jadro znika razem z pamiecia, w ktorej trzymalo logi, wiec
# wszystko, co ma zostac, musi trafic na nosnik wczesniej - stad zapis i sync
# po kazdym kroku. To, co dzieje sie PO skoku, widac wylacznie na ekranie
# telewizora: obraz docelowy ma framebuffer wbudowany, nie jako modul.
#
# Bez polskich znakow celowo - czcionka konsoli to CP437.

CEL=${1:-/mnt/vmlinuz-kexec-target.elf}
DTB=/mnt/ps2.dtb
KEXEC=/tmp/kexec
DEST=/mnt/logs-kexec

# Binarka idzie do /tmp, bo przed skokiem odmontowujemy nosnik - uruchamianie
# jej z /mnt skonczyloby sie tym, ze po umount nie ma czego uruchomic.
[ -x /mnt/kexec ] || { echo "BLAD: brak /mnt/kexec"; exit 1; }
cp /mnt/kexec "$KEXEC" && chmod +x "$KEXEC"
[ -f "$CEL" ] || { echo "BLAD: brak $CEL"; exit 1; }

mkdir -p "$DEST" 2>/dev/null
N=1
while [ -d "$DEST/proba-$N" ]; do
	N=$((N + 1))
done
RUN="$DEST/proba-$N"
mkdir -p "$RUN" || { echo "BLAD: nie moge pisac na $DEST"; exit 1; }

krok() {
	echo ">>> $*"
	echo "$*" >> "$RUN/postep.txt"
	sync
}

zbierz() {
	free > "$RUN/free-$1.txt" 2>&1
	cat /proc/meminfo > "$RUN/meminfo-$1.txt" 2>&1
	cat /proc/buddyinfo > "$RUN/buddyinfo-$1.txt" 2>&1
	dmesg > "$RUN/dmesg-$1.txt" 2>&1
	cat /sys/kernel/kexec_loaded > "$RUN/kexec_loaded-$1.txt" 2>&1
	sync
}

krok "start, cel $CEL"
uname -a > "$RUN/uname.txt" 2>&1
md5sum "$CEL" "$KEXEC" "$DTB" > "$RUN/md5.txt" 2>&1
lsmod > "$RUN/lsmod.txt" 2>&1
cat /proc/iomem > "$RUN/iomem.txt" 2>&1
zbierz przed

# --- zwolnienie pamieci ------------------------------------------------------
#
# Rootfs to tmpfs, wiec skasowanie modulow oddaje RAM natychmiast. Po skoku i
# tak startuje nowe jadro z wlasnym initramfsem, a gdyby skok sie nie udal,
# wystarczy restart konsoli.

krok "zwalniam pamiec: drop_caches + /lib/modules + /lib/firmware"
sync
echo 3 > /proc/sys/vm/drop_caches
rm -rf /lib/modules /lib/firmware
sync
echo 3 > /proc/sys/vm/drop_caches
zbierz po-zwolnieniu
krok "dostepne po zwolnieniu: $(awk '/MemAvailable/ {print $2 " kB"}' /proc/meminfo)"

# --- ladowanie ---------------------------------------------------------------

krok "kexec -l"
"$KEXEC" -d -l --dtb="$DTB" "$CEL" > "$RUN/kexec-load.txt" 2>&1
KOD=$?
krok "kexec -l zwrocil $KOD"
zbierz po-zaladowaniu

if [ "$(cat /sys/kernel/kexec_loaded 2>/dev/null)" != 1 ]; then
	krok "OBRAZ NIE ZALADOWANY - koniec, patrz kexec-load.txt"
	exit 1
fi
krok "obraz zaladowany (kexec_loaded=1)"

if [ "${SKOK:-tak}" != tak ]; then
	krok "SKOK=nie - zatrzymuje sie przed skokiem"
	exit 0
fi

# --- skok --------------------------------------------------------------------
#
# Odmontowanie nosnika przed skokiem: nowe jadro zastanie FAT w stanie czystym,
# a wszystko, co mielismy zapisac, jest juz zapisane.

krok "odmontowuje nosnik i skacze - dalszy ciag widac tylko na ekranie"
cd /
sync
umount /mnt 2>/dev/null
sync
# Od tego miejsca nosnika juz nie ma, wiec zaden zapis sie nie uda - wszystko,
# co mialo zostac, jest zapisane wyzej.

"$KEXEC" -e
