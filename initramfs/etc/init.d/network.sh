#!/bin/sh
#
# network.sh - bring the network up at boot, the way every other Linux does.
#
# A plugged cable is meant to be enough: the driver loads itself, address,
# gateway and DNS come from DHCP, SSH listens on port 2222.  Nobody types
# anything.
#
# The ordering is forced by the hardware: the SMAP driver needs the expansion
# bay powered by iop-dev9, so rcS calls this only AFTER modprobe iop-*.  It
# runs in the background so that a missing cable does not stall the boot.
#
# Manual setup, for a network without DHCP - put /mnt/network.conf on the
# storage device:
#
#   ADDRESS=192.168.1.60/24
#   GATEWAY=192.168.1.1
#   DNS=192.168.1.1
#
# ASCII only on purpose - the console font is CP437.

IFACE=eth0
PORT=2222
TRACE=/tmp/trace
mkdir -p "$TRACE"
LOG="$TRACE/network.txt"

log() {
	echo "$(date '+%H:%M:%S') $*" >> "$LOG"
}

log "start"

# --- driver ------------------------------------------------------------------
#
# The module ships inside the initramfs (lib/modules/.../extra), so it works
# with no storage device attached.  The copy on the device stays as a rescue
# path - that is what makes it possible to test a new build without rebuilding
# the kernel.

if modprobe ps2-smap 2>> "$LOG"; then
	log "modprobe ps2-smap ok"
elif [ -f /mnt/ps2-smap.ko ] && insmod /mnt/ps2-smap.ko 2>> "$LOG"; then
	log "fell back to /mnt/ps2-smap.ko"
else
	log "ERROR: driver did not load - giving up"
	exit 1
fi

[ -d /sys/class/net/$IFACE ] || { log "ERROR: no $IFACE"; exit 1; }

# --- carrier -----------------------------------------------------------------

ip link set dev $IFACE up
i=0
while [ $i -lt 20 ]; do
	[ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" = 1 ] && break
	sleep 1
	i=$((i + 1))
done

if [ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" != 1 ]; then
	log "no carrier after ${i}s - cable unplugged or switch silent, done"
	exit 0
fi
log "carrier after ${i}s"

# --- address: DHCP, unless someone left network.conf behind ------------------

if [ -r /mnt/network.conf ]; then
	. /mnt/network.conf
	log "manual configuration from /mnt/network.conf: $ADDRESS"
	ip addr flush dev $IFACE 2>/dev/null
	ip addr add "$ADDRESS" dev $IFACE
	[ -n "${GATEWAY:-}" ] && ip route add default via "$GATEWAY" dev $IFACE 2>/dev/null
	[ -n "${DNS:-}" ] && echo "nameserver $DNS" > /etc/resolv.conf
else
	# The lease script already sits in /usr/share/udhcpc/default.script, so
	# udhcpc needs no -s and behaves like it does on an ordinary system.
	timeout 90 udhcpc -i $IFACE -q -n -t 8 -T 3 >> "$LOG" 2>&1
fi

ADDR=$(ip addr show $IFACE 2>/dev/null | grep "inet " | head -1 | sed 's/^ *inet \([^ ]*\).*/\1/')
if [ -z "$ADDR" ]; then
	log "NO ADDRESS - DHCP did not answer; manual setup: /mnt/network.conf"
	exit 1
fi
log "address $ADDR"

# --- SSH ---------------------------------------------------------------------
#
# Port 2222, because 22 belongs to inetd.  -R generates host keys on the first
# connection, -B allows root in with an empty password.

DB=""
for f in /usr/sbin/dropbear /usr/bin/dropbear /sbin/dropbear; do
	[ -x "$f" ] && { DB="$f"; break; }
done
[ -z "$DB" ] && [ -x /usr/bin/dropbearmulti ] && DB="/usr/bin/dropbearmulti dropbear"

# Host key on the storage device.  The root filesystem is a tmpfs, so a key
# generated here would be new on every boot and every client would complain
# that the host had changed.  Keep one on the storage device instead and copy
# it in.  ed25519 only: RSA key generation takes minutes on a 294 MHz R5900,
# and nothing here needs it.
#
# The key ends up on a FAT filesystem, so it carries no permissions and
# anyone holding the storage device can read it.  With root logging in over
# SSH without a password, which is how this console is set up, that changes
# nothing.
KEYDIR=/mnt/ssh
HOSTKEY=/etc/dropbear/dropbear_ed25519_host_key

keygen() {
	if command -v dropbearkey > /dev/null 2>&1; then
		dropbearkey -t ed25519 -f "$1"
	elif [ -x /usr/bin/dropbearmulti ]; then
		/usr/bin/dropbearmulti dropbearkey -t ed25519 -f "$1"
	else
		return 1
	fi
}

mkdir -p /etc/dropbear

if [ -f /tmp/usb-ready ]; then
	mkdir -p "$KEYDIR" 2>/dev/null
	if [ ! -s "$KEYDIR/dropbear_ed25519_host_key" ]; then
		if keygen "$KEYDIR/dropbear_ed25519_host_key" >> "$LOG" 2>&1; then
			log "generated a new host key on $KEYDIR"
		else
			log "no way to generate a host key - dropbear will make its own"
		fi
		sync
	fi
	if [ -s "$KEYDIR/dropbear_ed25519_host_key" ]; then
		cp "$KEYDIR/dropbear_ed25519_host_key" "$HOSTKEY"
		log "host key taken from $KEYDIR"
	fi
else
	log "no storage device - host key will not survive this boot"
fi

if [ -n "$DB" ]; then
	# -r names the key to use; -R would generate a throwaway one on demand.
	[ -s "$HOSTKEY" ] && DB_KEY="-r $HOSTKEY" || DB_KEY="-R"
	$DB $DB_KEY -B -E -p "$PORT" 2>> "$TRACE/dropbear.txt" &
	sleep 2
	if netstat -ltn 2>/dev/null | grep -q ":$PORT "; then
		log "dropbear listening on $PORT"
	else
		log "dropbear NOT listening - see trace/dropbear.txt"
	fi
else
	log "no dropbear binary - SSH skipped"
fi

echo "network: $ADDR, ssh -p $PORT root@${ADDR%/*} (empty password)" > /dev/console 2>/dev/null

# The clock comes last, and in the background: SSH must not wait for a time
# server, and a machine with the wrong date is still a usable machine.
/etc/init.d/ntp.sh &

log "done"
