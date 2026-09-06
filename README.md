# PlayStation 2 Linux userland

Boot-time scripts and tooling for running Linux on a PlayStation 2, on top of
the kernel from [frno7/linux](https://github.com/frno7/linux).

Tested on an SCPH-30004 (PAL, ROM 0150) with a Network Adaptor in the
expansion bay, kernel 5.4.221, BusyBox 1.36.1.

## What is here

### `initramfs/`

The parts of the initramfs that are written rather than installed: everything
under `etc/`, plus the DHCP lease script. Binaries (BusyBox, dropbear) and
kernel modules are not in the repository; they come from the BusyBox build and
from `make modules_install`.

- `etc/init.d/rcS` - boot sequence. Module order is forced by the hardware:
  the USB controller lives on the I/O processor, so it needs `sif` and the
  `iop-*` family first.
- `etc/init.d/network.sh` - brings the network up by itself: loads the SMAP
  driver, waits for carrier, takes a DHCP lease and starts SSH on port 2222.
  A missing cable does not stall the boot. `/mnt/network.conf` on the storage
  device overrides DHCP with a static address.
- `etc/init.d/ntp.sh` - sets the clock from a time server once the network is
  up. The RTC battery is dead on this console, so every boot starts at the
  epoch and there is nothing local to fall back on.
- `usr/share/udhcpc/default.script` - applies the lease. Without it udhcpc
  obtains an address and does nothing with it, which is the usual surprise
  when using BusyBox as a DHCP client.

Boot leaves a trace in `/tmp/trace/` and, once the storage device is mounted,
copies it to `autolog/boot-N/` there, together with `dmesg` and the module
list. Nothing has to be collected by hand afterwards.

### `scripts/`

Run on the console, from the storage device:

- `ps2net2.sh` - bring up the network step by step, with a log of every step
- `przelacz-modul.sh` - swap the network driver from the console keyboard,
  falling back to the known good one if the new one does not load
- `przeladuj-zdalnie.sh` - the same swap driven from a laptop, detached from
  the SSH session that the swap itself takes down
- `ps2net-watchdog.sh` - watch the link and try to recover it
- `test-ata.sh` - check that the ATA driver and the network driver can share
  the expansion bay
- `kexec-proba.sh` - one kexec attempt, with the state saved before the jump
- `set-clock.sh` - set the clock from a timestamp on the storage device, for
  when there is no network

Run on the laptop:

- `wymien-modul.sh` - send a driver to the console and reload it, about 20
  seconds, no need to touch the console
- `wgraj-na-pendrive.sh` - copy files to the storage device
- `zbierz-logi.sh` - collect whatever the console has written that is not in
  the repository yet

### `build/`

Kernel and driver builds, all run inside the ps2dev container.

## Conventions

Anything that runs on the console is written in English and in plain ASCII -
the console font is CP437 and will not show anything else.
