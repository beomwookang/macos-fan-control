#!/bin/bash
# fanctl uninstaller. Run with sudo:  sudo ./uninstall.sh
set -uo pipefail

PREFIX=/usr/local
PLIST=/Library/LaunchDaemons/com.local.fanctl.plist
LABEL=com.local.fanctl
APP=/Applications/Fanctl.app
AGENT=com.local.fanctl.menubar
KEEP_CONF=1
[[ "${1:-}" == "--purge" ]] && KEEP_CONF=0

[[ $EUID -eq 0 ]] || { echo "run with sudo:  sudo $0" >&2; exit 1; }

echo "==> stopping the menu bar app"
# Before the daemon: a running app would just start it again.
pkill -f "$APP/Contents/MacOS/Fanctl" 2>/dev/null || true
if [[ -n "${SUDO_UID:-}" && -n "${SUDO_USER:-}" ]]; then
	launchctl bootout "gui/$SUDO_UID/$AGENT" 2>/dev/null || true
	# Do not assume the home directory is /Users/<name>; it may be elsewhere.
	home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
	[[ -n "$home" ]] && rm -f "$home/Library/LaunchAgents/$AGENT.plist"
fi

echo "==> stopping the daemon"
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl disable "system/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "==> restoring the fan to macOS automatic control"
[[ -x $PREFIX/bin/fanctl ]] && "$PREFIX/bin/fanctl" auto || true

echo "==> removing files"
rm -rf "$APP"
rm -f "$PREFIX/libexec/fanctl-admin" /etc/sudoers.d/fanctl
rm -f "$PREFIX/var/run/fanctl.paused"
rm -f "$PREFIX/bin/fanctl" /etc/newsyslog.d/fanctl.conf
rm -f "$PREFIX/var/log/fanctl.log" "$PREFIX/var/log/fanctl.log".*
if [[ $KEEP_CONF -eq 0 ]]; then
	rm -f "$PREFIX/etc/fanctl.conf" "$PREFIX/etc/fanctl.conf.default"
else
	echo "    keeping your config: $PREFIX/etc/fanctl.conf  (use --purge to remove it)"
fi
echo "Done."
