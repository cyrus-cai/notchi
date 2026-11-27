#!/usr/bin/env bash
#
# Checks an installed /Applications/Notchi.app after an install channel ran:
# the version matches, the signature verifies, the quarantine flag is gone,
# and the app launches and is still running 15 seconds later.
#
#   scripts/verify-install.sh 0.9.47
#
set -euo pipefail

expected="${1:?usage: verify-install.sh <version>}"
expected="${expected#v}"
app="/Applications/Notchi.app"
plist="$app/Contents/Info.plist"

fail() { echo "::error::$*"; exit 1; }

[ -d "$app" ] || fail "$app is not installed."

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")"
[ "$version" = "$expected" ] || fail "Installed version is $version, expected $expected."
echo "Version: $version"

codesign --verify --deep --strict "$app" || fail "codesign --verify failed."
echo "Signature verifies."

if xattr -r "$app" 2>/dev/null | grep -q com.apple.quarantine; then
  fail "The quarantine flag is still set on $app."
fi
echo "No quarantine flag."

exe="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")"
# The installers launch the app themselves; start it if it is not running.
pgrep -x "$exe" >/dev/null || open "$app"

for _ in $(seq 1 15); do
  pgrep -x "$exe" >/dev/null && break
  sleep 1
done
pgrep -x "$exe" >/dev/null || fail "$exe did not start."

sleep 15
pgrep -x "$exe" >/dev/null || fail "$exe exited within 15 seconds of launch."
echo "$exe is running (pid $(pgrep -x "$exe" | head -n1))."

pkill -x "$exe" || true
