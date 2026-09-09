#!/bin/bash
# Diagnostic: establish which SMC fan writes actually take on this machine.
# Run with sudo.
F="$(cd "$(dirname "$0")" && pwd)/build/fanctl"
[[ $EUID -eq 0 ]] || { echo "run with sudo: sudo $0"; exit 1; }
[[ -x $F ]] || { echo "build it first: make"; exit 1; }

hr() { printf '\n%s\n' "----------------------------------------------------------------"; }

LOADPIDS=()

# Portable load generator: one busy loop per logical core. Enough to move the
# die temperature, and needs nothing that is not already on the system.
start_load() {
	local n
	n=$(sysctl -n hw.ncpu)
	for ((i = 0; i < n; i++)); do
		yes >/dev/null 2>&1 &
		LOADPIDS+=($!)
	done
	echo "  started $n busy loops"
}

stop_load() {
	[[ ${#LOADPIDS[@]} -gt 0 ]] && kill "${LOADPIDS[@]}" 2>/dev/null
	LOADPIDS=()
}

# This script puts the fan into forced mode. However it exits -- including
# Ctrl-C -- it must hand control back to macOS before finishing.
restore() {
	echo
	stop_load
	echo ">>> restoring the fan to macOS automatic control (F0Md=0)"
	$F auto || echo "    failed - run 'sudo $F auto' yourself"
	$F status | sed -n '2,4p'
}
trap restore EXIT INT TERM

hr; echo "[0] competing tools"
ps aux | grep -iE "[m]acsfancontrol|[M]acs Fan|[s]mcFanControl|[T]G Pro" || echo "  none"
for h in com.crystalidea.macsfancontrol.smcwrite \
         com.tunabellysoftware.tgpro.helper \
         com.eidolon.smcFanControl.helper; do
	launchctl print "system/$h" >/dev/null 2>&1 \
		&& echo "  helper LOADED: $h" \
		|| echo "  helper absent: $h"
done

hr; echo "[1] starting state"
$F keyinfo F0Ac F0Tg F0Md F0Mn F0Mx

hr; echo "[2] set F0Md to 0 (automatic)"
$F trywrite F0Md 0

hr; echo "[3] set F0Tg to 3200"
$F trywrite F0Tg 3200

hr; echo "[4] set F0Mn to 2000"
$F trywrite F0Mn 2000

hr; echo "[5] reversed order: F0Tg first, then F0Md=1"
$F trywrite F0Tg 3400
$F trywrite F0Md 1

hr; echo "[6] do F0Tg / F0Ac move on their own over 30s (no load)?"
for i in $(seq 1 6); do
	printf "  t+%02ds  " $((i * 5))
	$F keyinfo F0Tg F0Ac F0Md | tail -3 | awk '{printf "%s=%s  ", $1, $6}'
	echo
	sleep 5
done

hr; echo "[7] under load, does the SMC raise the fan by itself over 30s?"
start_load
for i in $(seq 1 6); do
	printf "  t+%02ds  " $((i * 5))
	$F keyinfo F0Tg F0Ac | tail -2 | awk '{printf "%s=%s  ", $1, $6}'
	$F status | head -1 | sed 's/temp *//;s/ control.*//' | tr -d '\n'
	echo " C"
	sleep 5
done
stop_load
echo
echo "done."
