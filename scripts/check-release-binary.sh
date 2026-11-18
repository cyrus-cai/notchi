#!/bin/bash
# Fails when a Release build carries a test switch or a non-production gateway.
# Those live behind #if DEBUG; a match here means one was left outside it.
#
#   scripts/check-release-binary.sh build/Build/Products/Release/Notchi.app
set -euo pipefail
APP="${1:?usage: $0 <Notchi.app>}"
FORBIDDEN='debug\.license[A-Za-z]*|NoNoBaseURL|NONO_BASE_URL|NotchiLicensePreview[A-Za-z]*|workers\.dev|127\.0\.0\.1:8787'
DIRS=("$APP/Contents/MacOS")
[ -d "$APP/Contents/Frameworks" ] && DIRS+=("$APP/Contents/Frameworks")
hits=$(LC_ALL=C grep -raoE "$FORBIDDEN" "${DIRS[@]}" | sort -u || true)
if [ -n "$hits" ]; then
  echo "::error::Release build contains test-only strings:"
  echo "$hits"
  exit 1
fi
echo "Release binary check passed."
