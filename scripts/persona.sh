#!/usr/bin/env bash
#
# Notchi — switch which user this Mac runs as: your own state, or a new user.
#
#   ./scripts/persona.sh            # toggle between me and fresh
#   ./scripts/persona.sh fresh      # run as a new user (continues the last fresh user)
#   ./scripts/persona.sh fresh --new  # run as a brand-new user again (discards the last fresh user)
#   ./scripts/persona.sh me         # back to your own state
#   ./scripts/persona.sh status     # which one is active
#
# What moves: the com.notchglass.app preferences (settings, Notchi token, API
# keys, first-run flags), ~/Library/Application Support/{Notch,NotchGlass,Notchi}
# (history, memory, clipboard, logs), and the app's Caches / HTTPStorages.
# The inactive user's copy is kept in ~/.notch-personas/<name>. Nothing of
# "me" is ever deleted; a leftover copy is moved to a timestamped folder.
#
# Not touched: macOS permissions (Accessibility, Screen Recording) and the
# login item. Those belong to the system, not to the app's data.
#
set -euo pipefail

BUNDLE_ID="com.notchglass.app"
ROOT="$HOME/.notch-personas"
CURRENT_FILE="$ROOT/current"
SUPPORT="$HOME/Library/Application Support"
PATHS=(
  "$SUPPORT/Notch"
  "$SUPPORT/NotchGlass"
  "$SUPPORT/Notchi"
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"
)

bold=$'\033[1m'; red=$'\033[31m'; green=$'\033[32m'; reset=$'\033[0m'
info() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok()   { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
die()  { printf '%s✗%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

mkdir -p "$ROOT"
current="$(cat "$CURRENT_FILE" 2>/dev/null || echo me)"

target="${1:-}"
fresh_new=false
[ "${2:-}" = "--new" ] && fresh_new=true
case "$target" in
  "") target=$([ "$current" = me ] && echo fresh || echo me) ;;
  status) echo "$current"; exit 0 ;;
  me|fresh) ;;
  *) die "Usage: persona.sh [me|fresh [--new]|status]" ;;
esac

if [ "$target" = "$current" ] && ! $fresh_new; then
  ok "Already running as $current."
  exit 0
fi
[ "$target" = me ] && [ ! -d "$ROOT/me" ] && die "No saved copy at $ROOT/me — refusing to switch."

# --- quit the app, so nothing writes while the data moves -------------------
quit_app() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    pgrep -f "Notchi.app/Contents/MacOS" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  pkill -f "Notchi.app/Contents/MacOS" 2>/dev/null || true
  for _ in $(seq 1 25); do
    pgrep -f "Notchi.app/Contents/MacOS" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  die "Notchi did not quit."
}
info "Quitting Notchi…"
quit_app

# --- save the active user ---------------------------------------------------
save_to() {
  local dest="$1"
  if [ -e "$dest" ]; then
    mv "$dest" "$dest.leftover-$(date +%Y%m%d-%H%M%S)"
  fi
  mkdir -p "$dest/files"
  defaults export "$BUNDLE_ID" "$dest/prefs.plist" 2>/dev/null || true
  for p in "${PATHS[@]}"; do
    [ -e "$p" ] || continue
    local rel="${p#$HOME/}"
    mkdir -p "$dest/files/$(dirname "$rel")"
    mv "$p" "$dest/files/$rel"
  done
}

# --- load a saved user (or nothing, for a new one) ---------------------------
load_from() {
  local src="$1"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  for p in "${PATHS[@]}"; do
    [ -e "$p" ] && die "$p still exists after saving; stopping before anything is overwritten."
  done
  [ -d "$src" ] || return 0
  [ -f "$src/prefs.plist" ] && defaults import "$BUNDLE_ID" "$src/prefs.plist"
  for p in "${PATHS[@]}"; do
    local rel="${p#$HOME/}"
    [ -e "$src/files/$rel" ] || continue
    mkdir -p "$(dirname "$p")"
    mv "$src/files/$rel" "$p"
  done
  rm -rf "$src"
}

if [ "$target" = "$current" ]; then
  # fresh --new while already fresh: the current fresh user is discarded.
  info "Discarding the current fresh user…"
  save_to "$ROOT/fresh.discard"
  rm -rf "$ROOT/fresh.discard"
else
  info "Saving $current to $ROOT/${current}…"
  save_to "$ROOT/$current"
  if [ "$target" = fresh ] && $fresh_new && [ -d "$ROOT/fresh" ]; then
    rm -rf "$ROOT/fresh"
  fi
fi

info "Loading ${target}…"
if [ "$target" = fresh ] && [ ! -d "$ROOT/fresh" ]; then
  load_from ""
  ok "New user: empty preferences, no history, no account."
else
  load_from "$ROOT/$target"
fi
echo "$target" > "$CURRENT_FILE"

open -b "$BUNDLE_ID"
ok "Running as $target."
