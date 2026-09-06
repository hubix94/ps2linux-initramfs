#!/bin/sh
#
# ntp.sh - set the clock from the network.
#
# The RTC battery in this machine is dead, so the clock starts at the epoch
# on every boot and nothing on the console can tell the date on its own.
# Once the network is up, a time server can, which is the ordinary way any
# other machine solves this.
#
# Called by network.sh once an address is configured.  Runs in two stages:
# a single step to jump the clock, which may be a jump of decades, and then
# a daemon to hold it there.
#
# Servers come from DHCP when the server offers them (option 42, exported by
# udhcpc as $ntpsrv and written to /etc/ntpservers by the lease script), and
# from pool.ntp.org otherwise.
#
# ASCII only on purpose - the console font is CP437.

TRACE=/tmp/trace
mkdir -p "$TRACE"
LOG="$TRACE/ntp.txt"
FALLBACK="pool.ntp.org"

log() {
	echo "$(date '+%H:%M:%S') $*" >> "$LOG"
}

[ -r /etc/TZ ] && export TZ="$(head -1 /etc/TZ)"

SERVERS=""
[ -r /etc/ntpservers ] && SERVERS="$(cat /etc/ntpservers)"
[ -n "$SERVERS" ] || SERVERS="$FALLBACK"

ARGS=""
for s in $SERVERS; do
	ARGS="$ARGS -p $s"
done

log "start, servers:$SERVERS"
log "before: $(date)"

# -q: set the clock and quit, -n: stay in the foreground, -d: log what it did.
# The timeout is there because a server that never answers must not hold up
# the rest of the boot; without a clock the machine still works.
if timeout 60 ntpd -q -n -d $ARGS >> "$LOG" 2>&1; then
	log "after: $(date)"
	echo "clock set from network: $(date)" > /dev/console 2>/dev/null
else
	log "ERROR: no answer from $SERVERS - clock left alone"
	exit 1
fi

# Keep it there.  The console has no RTC to fall back on, so drift would
# otherwise accumulate for as long as the machine stays up.
ntpd -n $ARGS >> "$LOG" 2>&1 &
log "daemon started"
