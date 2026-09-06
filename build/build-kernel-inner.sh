#!/bin/bash
set -e
git config --global --add safe.directory '*'
cd /work/linux

export ARCH=mips
export CROSS_COMPILE=mipsr5900el-unknown-linux-gnu-
export INSTALL_MOD_PATH=../initramfs
export INSTALL_MOD_STRIP=1
J=$(getconf _NPROCESSORS_ONLN)

echo "===== defconfig ====="
make ps2_defconfig

# Znaczniki czasu w dmesg. W ps2_defconfig PRINTK_TIME jest wylaczone, przez co
# logi z konsoli nie pozwalaja zmierzyc NICZEGO w czasie - a akurat na PS2 jest
# co mierzyc: framebuffer to modul ladowany dopiero przez rcS, wiec caly start
# jadra leci na czarnym ekranie i nie wiadomo, jak dlugo.
#
# Ustawiane tutaj, a nie w arch/mips/configs/ps2_defconfig, bo defconfig lezy
# w sklonowanym repo autora, w ktorym nie piszemy.
echo "===== wlasne zmiany konfiguracji ====="
./scripts/config --enable PRINTK_TIME

make olddefconfig
echo "===== CONFIG_INITRAMFS_SOURCE ====="
grep CONFIG_INITRAMFS_SOURCE .config
echo "===== sprawdzenie, ze zmiany przetrwaly olddefconfig ====="
grep '^CONFIG_PRINTK_TIME=' .config || { echo "BLAD: PRINTK_TIME nie ustawione"; exit 1; }

echo "===== vmlinux (-j$J) ====="
make -j"$J" vmlinux
echo "===== modules ====="
make -j"$J" modules
make modules_install
rm -f ../initramfs/lib/modules/*/{build,modules.*,source}
echo "===== vmlinuz ====="
make vmlinuz

echo "===== WYNIK ====="
ls -l vmlinuz vmlinux
