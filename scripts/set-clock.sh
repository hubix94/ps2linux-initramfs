#!/bin/sh
#
# set-clock.sh - a clock on a console with a dead RTC battery and no network.
#
# NOT part of the kernel image on purpose.  This is a local workaround for one
# console with a dead battery, not a solution anyone else should inherit: run
# it by hand when the date matters.
#
#   sh /mnt/scripts/set-clock.sh
#
# The proper fix is NTP once the network comes up by itself, or a new battery.
#
# The RTC battery in this machine is dead, so every boot starts in 1970 and
# every file written to the storage device gets a stone-age date.  This script
# takes the latest date it can find locally, without asking anyone:
#
#   1. /mnt/time.txt    - stamped when files are copied to the storage device
#                         (scripts/wgraj-na-pendrive.sh) and refreshed while
#                         the console is running, by this script
#   2. file dates on the storage device - last resort, for a hand copy
#
# ...and sets the clock to the latest of them.  Then it writes the current
# time back to /mnt/time.txt every 15 minutes, so the next boot falls back no
# further than the end of the previous session.
#
# Accuracy: minutes, not seconds.  That is enough for files to carry sensible
# dates and for logs to be ordered.  NTP replaces this once the network comes
# up on its own.
#
# ASCII only on purpose - the console font is CP437.

STORAGE_TIME=/mnt/time.txt
TRACE=/tmp/trace
mkdir -p "$TRACE"
LOG="$TRACE/clock.txt"
INTERVAL=900

log() { echo "$*" >> "$LOG"; }

# BusyBox understands "date -s @seconds", but not every build does - the
# fallback is the classic MMDDhhmmYYYY.ss format, computed in UTC.
set_clock() {
	date -s "@$1" >/dev/null 2>&1 && return 0
	s=$(date -u -d "@$1" +%m%d%H%M%Y.%S 2>/dev/null) || return 1
	[ -n "$s" ] || return 1
	date -u -s "$s" >/dev/null 2>&1
}

write_stamp() {
	[ -f /tmp/usb-ready ] || return 1
	{
		date +%s
		date -u +%m%d%H%M%Y.%S
	} > "$STORAGE_TIME.new" 2>/dev/null || return 1
	mv "$STORAGE_TIME.new" "$STORAGE_TIME" 2>/dev/null
}

# rcS does not read /etc/profile, so the zone is set here.  The stamps
# themselves are plain seconds since the epoch, but the log should be readable.
[ -r /etc/TZ ] && export TZ="$(head -1 /etc/TZ)"

# Sources come in two kinds, and this is the whole lesson of 2026-09-06:
#
#   TRUSTED   - stamps written as plain seconds since the epoch: /etc/build-date
#               and /mnt/time.txt.  Independent of time zones and of how the
#               kernel reads FAT.
#   LAST DITCH - file dates on the storage device.  FAT stores local time and
#               the kernel reads it as UTC, so in our zone they come out TWO
#               HOURS AHEAD.  The first version of this script took the maximum
#               over all sources at once - and that wrong value always beat the
#               correct one.  File dates are now used only when there is no
#               trusted stamp at all.
TRUSTED=""
FALLBACK=""

# The storage device appears a few seconds into the boot, so wait for it - but
# not forever, because the build stamp alone is still better than 1970.
i=0
while [ $i -lt 60 ] && [ ! -f /tmp/usb-ready ]; do
	sleep 1
	i=$((i + 1))
done

if [ -f /tmp/usb-ready ]; then
	[ -r "$STORAGE_TIME" ] && TRUSTED="$TRUSTED $(head -1 "$STORAGE_TIME")"

	for f in /mnt/vmlinuz-pal-latest.elf /mnt/scripts/ps2net2.sh; do
		[ -e "$f" ] || continue
		t=$(date -r "$f" +%s 2>/dev/null) && FALLBACK="$FALLBACK $t"
	done
else
	log "no storage device - build stamp only"
fi

largest() {
	max=0
	for t in $1; do
		case "$t" in ""|*[!0-9]*) continue ;; esac
		[ "$t" -gt "$max" ] && max="$t"
	done
	echo "$max"
}

BEST=$(largest "$TRUSTED")
SOURCE="stamp"

if [ "$BEST" = 0 ]; then
	BEST=$(largest "$FALLBACK")
	SOURCE="FAT file date (may be up to 2 h ahead)"
fi

NOW=$(date +%s)
if [ "$BEST" -gt "$NOW" ]; then
	if set_clock "$BEST"; then
		log "set to $(date) - source: $SOURCE ($BEST)"
		echo "clock set to $(date)"
	else
		log "ERROR: date rejected stamp $BEST"
	fi
else
	log "clock already later than the stamps - leaving $(date)"
fi

write_stamp && log "stamp written to storage"

# One line per boot straight onto the storage device - without it the only
# trace of the clock lives in /tmp and dies with the console.
if [ -f /tmp/usb-ready ]; then
	echo "$(date '+%Y-%m-%d %H:%M:%S') boot: $BEST from '$SOURCE'; trusted:$TRUSTED fallback:$FALLBACK" \
		>> /mnt/time-log.txt 2>/dev/null
	sync
fi

# Ratchet: while the system runs, the storage device gets a fresh time every
# 15 minutes, so the next boot knows when the previous session ended.
while true; do
	sleep "$INTERVAL"
	write_stamp
done &
