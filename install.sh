#!/bin/bash
# fanctl installer. Run with sudo:  sudo ./install.sh
set -euo pipefail

PREFIX=/usr/local
BIN=$PREFIX/bin/fanctl
CONF=$PREFIX/etc/fanctl.conf
LOG=$PREFIX/var/log/fanctl.log
PLIST=/Library/LaunchDaemons/com.local.fanctl.plist
LABEL=com.local.fanctl
ADMIN=$PREFIX/libexec/fanctl-admin
SUDOERS=/etc/sudoers.d/fanctl
APP=/Applications/Fanctl.app
HERE="$(cd "$(dirname "$0")" && pwd)"
YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo:  sudo $0"
[[ "$(uname -s)" == Darwin ]] || die "macOS only."

# --- check for competing fan tools ---------------------------------------
# Look for the privileged helpers these apps install, not just their GUIs:
# killing only the GUI leaves the helper holding the SMC keys.
HELPERS=(
	com.crystalidea.macsfancontrol.smcwrite
	com.tunabellysoftware.tgpro.helper
	com.eidolon.smcFanControl.helper
)

conflicts=$(pgrep -fl 'Macs Fan Control|smcFanControl|TG Pro' 2>/dev/null || true)
live_helpers=()
for h in "${HELPERS[@]}"; do
	launchctl print "system/$h" >/dev/null 2>&1 && live_helpers+=("$h")
done

if [[ -n "$conflicts" || ${#live_helpers[@]} -gt 0 ]]; then
	echo "Another fan control tool is running. They write the same SMC keys and"
	echo "will overwrite each other, leaving both misbehaving."
	[[ -n "$conflicts" ]] && { echo "  apps:"; echo "$conflicts" | sed 's/^/    /'; }
	if [[ ${#live_helpers[@]} -gt 0 ]]; then
		echo "  privileged helpers (resident as root):"
		printf '    %s\n' "${live_helpers[@]}"
	fi
	echo
	echo "The apps have to be quit and the helpers unloaded. Unloading a helper"
	echo "does not remove its plist, so reopening that app restores it."
	echo "(To stop Macs Fan Control coming back: Preferences -> uncheck 'Start at login')"
	if [[ $YES -eq 0 ]]; then
		read -rp "Quit and unload them now? [y/N] " a
		[[ "$a" == y || "$a" == Y ]] || die "install aborted."
	fi
	pkill -f 'Macs Fan Control' 2>/dev/null || true
	pkill -f 'smcFanControl'    2>/dev/null || true
	pkill -f 'TG Pro'           2>/dev/null || true
	for h in "${live_helpers[@]}"; do
		launchctl bootout "system/$h" 2>/dev/null || true
	done
	sleep 2

	still=$(pgrep -fl 'Macs Fan Control|smcFanControl|TG Pro' 2>/dev/null || true)
	for h in "${HELPERS[@]}"; do
		launchctl print "system/$h" >/dev/null 2>&1 && still+=$'\n'"  helper $h"
	done
	[[ -n "$still" ]] && die "still running:$still"
	echo "Cleared."
	echo
fi

# --- build ----------------------------------------------------------------
# Building here rather than shipping a binary matters: the .app is ad-hoc
# signed, so a bundle copied from another machine picks up a quarantine flag
# and macOS refuses to launch it. A locally built bundle has no such flag.
if [[ ! -x "$HERE/build/fanctl" || ! -d "$HERE/build/Fanctl.app" ]]; then
	for t in clang swiftc make; do
		command -v "$t" >/dev/null 2>&1 || die "$t not found. Install the Xcode Command Line Tools first:
    xcode-select --install"
	done
	echo "==> building"
	( cd "$HERE" && make )
fi

# --- stop any previous version --------------------------------------------
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
	echo "==> stopping the existing daemon"
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	sleep 1
fi

# --- install files --------------------------------------------------------
echo "==> installing files"
install -d -m 755 "$PREFIX/bin" "$PREFIX/etc" "$PREFIX/var/log"
install -m 755 -o root -g wheel "$HERE/build/fanctl" "$BIN"

if [[ -f "$CONF" ]]; then
	echo "    $CONF already exists, keeping it (new defaults are in $CONF.default)"
	install -m 644 "$HERE/fanctl.conf" "$CONF.default"
else
	install -m 644 "$HERE/fanctl.conf" "$CONF"
fi
install -d -m 755 /etc/newsyslog.d
install -m 644 "$HERE/newsyslog-fanctl.conf" /etc/newsyslog.d/fanctl.conf
touch "$LOG"; chown root:wheel "$LOG"; chmod 644 "$LOG"
install -d -m 755 "$PREFIX/var/run"

# The root helper the menu bar app calls. The sudoers rule below permits this
# one script without a password, so the real security boundary is the verb list
# inside it, not sudoers. Hence: owned by root, not writable by the user, and
# it must never pass caller input to a shell.
echo "==> installing the privileged helper"
install -d -m 755 "$PREFIX/libexec"
install -m 755 -o root -g wheel "$HERE/fanctl-admin" "$ADMIN"

tmp_sudoers=$(mktemp)
cat >"$tmp_sudoers" <<SUDO
# Lets the fanctl menu bar app act without prompting for a password on every
# click. Only the script below is permitted, and it runs a fixed set of verbs.
%admin ALL=(root) NOPASSWD: $ADMIN
SUDO
if visudo -cf "$tmp_sudoers" >/dev/null 2>&1; then
	install -m 440 -o root -g wheel "$tmp_sudoers" "$SUDOERS"
	rm -f "$tmp_sudoers"
else
	rm -f "$tmp_sudoers"
	die "the sudoers rule did not validate. Aborting."
fi

# --- find out which control method works on this model --------------------
echo
echo "==> verifying SMC writes (your fan will be loud for about 30 seconds)"
echo
st=$("$BIN" selftest || true)
echo "$st"
echo

if grep -q 'mode = floor' <<<"$st"; then
	want=floor
elif grep -q 'mode = force' <<<"$st"; then
	want=force
else
	die "SMC writes are not working at all. Check whether another fan app is running."
fi

cur=$(awk -F= '/^[[:space:]]*mode[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2}' "$CONF" | tail -1)
if [[ "$cur" != "$want" ]]; then
	echo "==> setting mode = $want in the config (from the selftest result; was: ${cur:-unset})"
	if grep -qE '^[[:space:]]*mode[[:space:]]*=' "$CONF"; then
		sed -i '' -E "s/^[[:space:]]*mode[[:space:]]*=.*/mode = $want/" "$CONF"
	else
		printf '\nmode = %s\n' "$want" >>"$CONF"
	fi
fi

# --- register the app and daemon ------------------------------------------
echo "==> installing the menu bar app"
rm -rf "$APP"
cp -R "$HERE/build/Fanctl.app" "$APP"
# Left owned by root, which is normal for /Applications and is not needed for
# the user to run it. Everything privileged goes through sudoers + fanctl-admin.
chown -R root:admin "$APP"

echo "==> registering the daemon"
install -m 644 -o root -g wheel "$HERE/com.local.fanctl.plist" "$PLIST"
# A previous uninstall may have disabled it, which makes bootstrap fail quietly.
launchctl enable "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
sleep 4

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
	echo
	echo "Done."
	echo
	"$BIN" status
	echo
	echo "  config     $CONF"
	echo "  log        tail -f $LOG"
	echo "  status     fanctl status"
	echo "  uninstall  sudo $HERE/uninstall.sh"
	echo
	echo "Open the menu bar app and an icon appears in the menu bar:"
	echo "  open -a $APP"
	echo "Quitting the app stops the daemon as well."
else
	die "the daemon did not come up. Check the log: $LOG"
fi
