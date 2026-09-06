#!/bin/bash
#
# wymien-modul.sh - wgraj nowy ps2-smap.ko na konsole i przeladuj go ZDALNIE,
# bez ruszania pendrive'a i bez wyjazdu do telewizora.
#
#   ./scripts/wymien-modul.sh                        # work/smap/ps2-smap.ko
#   ./scripts/wymien-modul.sh inny.ko 192.168.1.47 poll=2
#
# Dziala od sterownika v10, ktory budzi PHY przed resetem EMAC3 - wczesniejsze
# wersje po rmmod nie wstawaly bez restartu konsoli i zdalna wymiana konczyla
# sie utrata lacznosci (2026-09-06, patrz FACTS.md).
#
# Polaczenie padnie w trakcie - to normalne, modul niesie interfejs, przez
# ktory idzie sesja. Robota po stronie konsoli jest odczepiona od tej sesji
# (setsid), wiec konczy sie mimo zerwania SSH. Skrypt czeka, az konsola
# wroci, i pokazuje log z jej strony.
set -u

KO=${1:-work/smap/ps2-smap.ko}
IP=${2:-192.168.1.47}
PARAM=${3:-}
PORT=2222
ZDALNY=/mnt/scripts/przeladuj-zdalnie.sh

[ -f "$KO" ] || { echo "BLAD: brak $KO"; exit 1; }

printf '#!/bin/sh\necho ""\n' > /tmp/askpass.sh
chmod +x /tmp/askpass.sh
SSHOPT=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
	-o PubkeyAuthentication=no -o PreferredAuthentications=password
	-o NumberOfPasswordPrompts=1 -o ConnectTimeout=10)

run() {
	SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
		timeout 60 ssh "${SSHOPT[@]}" -p $PORT root@"$IP" "$@" < /dev/null
}

wyslij() {
	# scp odpada: OpenSSH 9 idzie przez SFTP, a dropbear nie ma sftp-server.
	SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
		timeout 120 ssh "${SSHOPT[@]}" -p $PORT root@"$IP" "cat > $2" < "$1"
}

MD5=$(md5sum "$KO" | cut -d' ' -f1)
echo "== wysylam $KO (md5 $MD5) =="
wyslij "$KO" /tmp/ps2-smap-nowy.ko || exit 1
wyslij scripts/przeladuj-zdalnie.sh "$ZDALNY" || exit 1

ZDALNY_MD5=$(run "sync; md5sum /tmp/ps2-smap-nowy.ko" | cut -d' ' -f1)
if [ "$ZDALNY_MD5" != "$MD5" ]; then
	echo "BLAD: md5 na konsoli ($ZDALNY_MD5) rozni sie od lokalnego ($MD5)"
	exit 1
fi
echo "== md5 zgodne, przeladowuje (sesja zaraz padnie) =="

run "setsid sh $ZDALNY /tmp/ps2-smap-nowy.ko $PARAM > /tmp/przeladuj.out 2>&1 &" || true

# Pierwsze sekundy stary modul jeszcze zyje i ping przechodzi - bez tego
# odczekania brano to za udany powrot.
sleep 20
for i in $(seq 1 40); do
	sleep 3
	if ping -c 1 -W 2 "$IP" > /dev/null 2>&1; then
		echo "== konsola wrocila po $((20 + i * 3)) s =="
		sleep 2
		run 'N=$(ls -d /mnt/logs-net/wymiana-* | tail -1); cat "$N/postep.txt"; echo "--- sterownik:"; tail -6 "$N/dmesg-sterownik.txt"; echo "--- adres:"; grep "inet " "$N/ip-addr.txt"'
		exit 0
	fi
done

echo "BLAD: konsola nie wrocila w 140 s."
echo "Log po jej stronie: /mnt/logs-net/wymiana-*/postep.txt - do odczytania z klawiatury albo po restarcie."
exit 1
