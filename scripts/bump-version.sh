#!/usr/bin/env bash
#
# Sets the release version in every file that stores it:
#   - MARKETING_VERSION in NotchGlass.xcodeproj/project.pbxproj (all configs)
#   - "version" in npm/package.json
#
#   ./scripts/bump-version.sh 0.9.48
#
# WhatsNewService.bundled still needs its entry written by hand; the release
# notes are not generated. check-roadmap.sh and release.yml fail if any of
# these disagree.
#
set -euo pipefail
cd "$(dirname "$0")/.."

new="${1:?usage: bump-version.sh <x.y.z>}"
new="${new#v}"
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Not a version: $new" >&2; exit 1; }

PBXPROJ="NotchGlass.xcodeproj/project.pbxproj"
PKG="npm/package.json"

cur=$(grep -oE 'MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+' "$PBXPROJ" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
if [[ -n "$cur" && "$new" != "$cur" ]] \
   && [[ "$(printf '%s\n%s\n' "$cur" "$new" | sort -V | tail -1)" == "$cur" ]]; then
  echo "Refusing to go from $cur down to $new." >&2
  exit 1
fi

sed -i '' -E "s/MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+;/MARKETING_VERSION = $new;/" "$PBXPROJ"

node -e '
  const fs = require("fs");
  const [file, v] = process.argv.slice(1);
  const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
  pkg.version = v;
  fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");
' "$PKG" "$new"

echo "MARKETING_VERSION: ${cur:-unset} -> $new"
echo "npm/package.json:  $new"
grep -q "version: \"$new\"" NotchGlass/Sources/WhatsNewService.swift \
  || echo "WhatsNewService.bundled has no $new entry yet. Write it before releasing."
