#!/bin/bash
# Budowa modulu diagnostycznego SMAP poza drzewem jadra.
#
# Uruchamiane w kontenerze, tak samo jak build-kernel-inner.sh:
#   sudo docker exec ps2dev bash /work/build-smap.sh
#
# W kontenerze /work to korzen projektu, wiec zrodla leza w
# /work/work/smap, a jadro w /work/linux.
set -e

git config --global --add safe.directory '*'

export ARCH=mips
export CROSS_COMPILE=mipsr5900el-unknown-linux-gnu-

KDIR=/work/linux
MDIR=/work/work/smap

# Modul poza drzewem wymaga, zeby jadro bylo juz zbudowane - potrzebne sa
# Module.symvers i zbudowane skrypty. Jesli ich nie ma, przerywamy z jasnym
# komunikatem zamiast tonac w bledach kbuilda.
if [ ! -f "$KDIR/Module.symvers" ]; then
	echo "BLAD: brak $KDIR/Module.symvers"
	echo "Najpierw: sudo docker exec ps2dev bash /work/build-kernel-inner.sh"
	exit 1
fi

echo "===== vermagic jadra ====="
grep -m1 UTS_RELEASE "$KDIR/include/generated/utsrelease.h" || true

# Module.symvers po build-kernel-inner.sh zawiera tylko symbole z vmlinux -
# koncowe "make vmlinuz" nadpisuje plik wygenerowany wczesniej przez
# "make modules" i gubi eksporty z modulow. Bez nich modul poza drzewem nie
# zlinkuje sie z iop_readw/iop_writew/iop_set_dma_dpcr2, ktore pochodza
# z iop-module.ko i iop-registers.ko. To przelicza je z powrotem; jest
# przyrostowe, wiec tanie.
echo "===== odtworzenie Module.symvers z eksportami modulow ====="
make -C "$KDIR" modules >/dev/null
grep -q 'iop_readw' "$KDIR/Module.symvers" || {
	echo "BLAD: w Module.symvers nadal brak iop_readw"
	exit 1
}
echo "iop_readw obecny w Module.symvers"

echo "===== budowa ====="
make -C "$KDIR" M="$MDIR" modules

echo "===== strip ====="
for m in ps2-smap-probe ps2-smap; do
	"${CROSS_COMPILE}strip" --strip-debug "$MDIR/$m.ko"
done

# Sterownik ma jechac w initramfsie, zeby siec wstawala z samego ELF-a, bez
# pendrive'a. Kopia na nosniku zostaje jako droga ratunkowa i poletko testowe.
echo "===== kopia do initramfsu ====="
KVER=$(cat "$KDIR/include/config/kernel.release" 2>/dev/null || echo "5.4.221+")
mkdir -p "/work/initramfs/lib/modules/$KVER/extra"
cp "$MDIR/ps2-smap.ko" "/work/initramfs/lib/modules/$KVER/extra/ps2-smap.ko"
md5sum "/work/initramfs/lib/modules/$KVER/extra/ps2-smap.ko"

echo "===== WYNIK ====="
ls -l "$MDIR"/ps2-smap-probe.ko "$MDIR"/ps2-smap.ko
echo "--- symbole niezdefiniowane sterownika (musza byc w jadrze albo w zaladowanych modulach):"
"${CROSS_COMPILE}nm" -u "$MDIR/ps2-smap.ko" | grep -v "^ *U \(__\|printk\|kmalloc\|kfree\|memcpy\|memset\|strlcpy\|snprintf\)" | awk '{print $2}' | tr '\n' ' '
echo

echo
echo "Sonda:      work/smap/ps2-smap-probe.ko  (+ scripts/ps2net1.sh)"
echo "Sterownik:  work/smap/ps2-smap.ko        (+ scripts/ps2net2.sh, scripts/udhcpc.sh)"
