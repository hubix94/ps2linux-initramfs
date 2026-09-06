#!/bin/bash
#
# Chudy obraz do testow kexec (issue #92 autora): ten sam kernel, ale
# initramfs bez 113 modulow - zostaje 19 tych, ktore sa faktycznie uzywane.
# Mniejszy obraz to mniejszy MemSiz, a to on decyduje, ile stron jadro musi
# zaalokowac przy kexec_load na maszynie z 32 MB.
#
# Moduly instalowane sa poza drzewem initramfsu, zeby nie nadpisac chudej
# kopii tym, co wlasnie zbudowalismy.
set -e
git config --global --add safe.directory '*'
cd /work/linux

export ARCH=mips
export CROSS_COMPILE=mipsr5900el-unknown-linux-gnu-
export INSTALL_MOD_PATH=/tmp/slim-modules
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
./scripts/config --set-str INITRAMFS_SOURCE "../initramfs-slim"

# Framebuffer WBUDOWANY, nie modulem. Po skoku kexec nowe jadro nie ma jak
# nic powiedziec: ps2fb jako modul wchodzi dopiero z rcS, wiec caly wczesny
# rozruch leci na czarnym ekranie i awaria wyglada jak zawieszenie. Z
# wbudowanym framebufferem ekran jest jedynym logiem, jaki mamy.
./scripts/config --enable FB_PS2
./scripts/config --set-val CMDLINE_BOOL y
./scripts/config --set-str CMDLINE "ps2fb.mode_option=640x512i@50"

make olddefconfig
echo "===== CONFIG_INITRAMFS_SOURCE ====="
grep CONFIG_INITRAMFS_SOURCE .config
echo "===== sprawdzenie, ze zmiany przetrwaly olddefconfig ====="
grep '^CONFIG_PRINTK_TIME=' .config || { echo "BLAD: PRINTK_TIME nie ustawione"; exit 1; }
grep '^CONFIG_INITRAMFS_SOURCE="../initramfs-slim"' .config || { echo "BLAD: initramfs-slim nie ustawiony"; exit 1; }
grep '^CONFIG_FB_PS2=y' .config || { echo "BLAD: ps2fb nie jest wbudowany"; exit 1; }

echo "===== vmlinux (-j$J) ====="
make -j"$J" vmlinux
echo "===== modules ====="
make -j"$J" modules
make modules_install
rm -f /tmp/slim-modules/lib/modules/*/{build,modules.*,source}
echo "===== vmlinuz ====="
make vmlinuz

echo "===== WYNIK ====="
ls -l vmlinuz vmlinux
