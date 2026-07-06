#!/usr/bin/env bash
#
# Notchi — one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/cyrus-cai/notchi/master/install.sh | bash
#
# Downloads the latest release, installs Notchi.app into /Applications, and
# clears the macOS quarantine flag so it opens without a Gatekeeper prompt.
#
set -euo pipefail

REPO="cyrus-cai/notchi"
APP_NAME="Notchi.app"
INSTALL_DIR="/Applications"

# --- pretty output ---------------------------------------------------------
bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; reset=$'\033[0m'
info()  { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok()    { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
die()   { printf '%s✗%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "Notchi is a macOS app — this installer only runs on macOS."
command -v curl >/dev/null 2>&1 || die "curl is required but not found."

# --- find the latest release asset -----------------------------------------
info "Looking up the latest release of ${REPO}…"
api="https://api.github.com/repos/${REPO}/releases/latest"
release_json="$(curl -fsSL "$api")" || die "Could not reach the GitHub API."

# Pull the first .zip browser_download_url out of the release JSON (no jq dependency).
asset_url="$(printf '%s' "$release_json" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' \
  | head -n1 \
  | sed -E 's/.*"(https[^"]+)".*/\1/')"

tag="$(printf '%s' "$release_json" \
  | grep -o '"tag_name": *"[^"]*"' \
  | head -n1 \
  | sed -E 's/.*"([^"]+)".*/\1/')"

[ -n "$asset_url" ] || die "No .zip asset found on the latest release. Has one been published yet?"
ok "Found ${tag:-latest}: $(basename "$asset_url")"

# --- download into a temp dir ----------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
zip="$tmp/notch.zip"

info "Downloading…"
curl -fsSL "$asset_url" -o "$zip" || die "Download failed."

info "Unpacking…"
ditto -x -k "$zip" "$tmp/extracted" || die "Could not unzip the archive."

# Accept the current bundle name or the legacy "Notch.app" / "NotchGlass.app"
# so this installer keeps working against releases published before the renames.
src="$(/usr/bin/find "$tmp/extracted" -maxdepth 2 \( -name "$APP_NAME" -o -name "Notch.app" -o -name "NotchGlass.app" \) -type d | head -n1)"
[ -n "$src" ] || die "Could not find ${APP_NAME} inside the archive."

# --- install ---------------------------------------------------------------
# `ditto "$src" "$dest"` copies the bundle's contents to $dest, so the installed
# bundle takes the $dest name (Notchi.app) regardless of the archive's name.
dest="$INSTALL_DIR/$APP_NAME"
if [ -d "$dest" ]; then
  info "Replacing existing ${APP_NAME}…"
  rm -rf "$dest" 2>/dev/null || die "Could not remove old ${dest} (try: sudo rm -rf \"$dest\")."
fi
# Remove any leftover bundles from before the renames so we don't leave two copies.
for legacy in "$INSTALL_DIR/Notch.app" "$INSTALL_DIR/NotchGlass.app"; do
  if [ -d "$legacy" ]; then
    info "Removing legacy $(basename "$legacy")…"
    rm -rf "$legacy" 2>/dev/null || true
  fi
done

info "Installing to ${INSTALL_DIR}…"
ditto "$src" "$dest" || die "Could not copy into ${INSTALL_DIR} (you may need write permission)."

# --- clear quarantine so it opens without a Gatekeeper prompt ---------------
# The app is not notarized; downloaded apps carry a quarantine flag that makes
# macOS refuse to open them. Strip it, the same way Homebrew cask does.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

ok "Notchi installed to ${dest}"
info "Launching…"
open "$dest" || true
printf '\n%sDone.%s Hover your notch to wake it. Quit with: %spkill -f Notchi.app%s\n' \
  "$bold" "$reset" "$dim" "$reset"
