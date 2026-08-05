#!/usr/bin/env bash
#
# Notchi — local dev reinstall.
#
# Builds the app from local source (Debug), replaces /Applications/Notchi.app
# with the freshly-built bundle, and relaunches it. This is the dev loop's
# "reinstall" — it picks up uncommitted local changes, unlike install.sh which
# pulls the latest published GitHub release.
#
#   ./scripts/reinstall.sh
#
set -euo pipefail

# Run from the repo root regardless of where this is invoked from.
cd "$(dirname "$0")/.."

PROJECT="NotchGlass.xcodeproj"
SCHEME="NotchGlass"
CONFIG="Debug"
# The Xcode target is still "NotchGlass", but PRODUCT_NAME is "Notchi", so the
# built bundle and executable are named Notchi — that's what the Dock shows.
APP_NAME="Notchi.app"
INSTALL_DIR="/Applications"

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; reset=$'\033[0m'
info()  { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok()    { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
die()   { printf '%s✗%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

# --- concurrency lock --------------------------------------------------------
# Two reinstalls interleaving their pkill→open sequences is how the app ends up
# running twice (a pkill can miss the other pass's instance while it's still in
# its fork/exec window). One reinstall at a time. mkdir is the atomic primitive
# (macOS ships no flock(1)); a pid file inside detects a stale lock left by a
# hard-killed run.
LOCK="/tmp/notch-reinstall.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    die "Another reinstall (pid $holder) is already running."
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || die "Could not take the reinstall lock at $LOCK."
fi
echo "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# --- build -----------------------------------------------------------------
info "Building ${SCHEME} (${CONFIG})…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" build \
  >/tmp/notch-reinstall-build.log 2>&1 \
  || { tail -40 /tmp/notch-reinstall-build.log; die "Build failed (full log: /tmp/notch-reinstall-build.log)."; }
ok "Build succeeded."

# --- locate the freshly-built bundle ---------------------------------------
# DerivedData paths carry a per-project hash, so resolve it from build settings
# rather than hardcoding it.
built_dir="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
src="$built_dir/$APP_NAME"
[ -d "$src" ] || die "Built app not found at $src."

# --- sign ------------------------------------------------------------------
# Sign the dev build with the same certificate CI uses. Xcode's default
# "Sign to Run Locally" is an ad-hoc signature whose designated requirement is
# the binary's own hash, so every reinstall used to invalidate the Accessibility
# grant — the toggle stayed on in System Settings while the permission silently
# stopped working. Signing with the shared certificate gives Debug and Release
# an identical DR, so one grant covers both and survives every rebuild.
#
# This is best-effort locally: without the certificate the script falls back to
# ad-hoc (with a warning) so the dev loop still works. Run
# scripts/make-signing-cert.sh once to stop the permission drops.
./scripts/codesign-app.sh --debug "$src"

# --- stop the running instance ---------------------------------------------
# Kill any running copy so the replace can't hit a busy bundle and the relaunch
# starts the new build clean. (No error if nothing is running.)
info "Stopping any running ${APP_NAME}…"
pkill -f "$APP_NAME/Contents/MacOS" 2>/dev/null || true
# Also stop any legacy Notch.app / NotchGlass.app process from before the renames.
pkill -f "Notch.app/Contents/MacOS" 2>/dev/null || true
pkill -f "NotchGlass.app/Contents/MacOS" 2>/dev/null || true
# Give the process a moment to release the bundle before we overwrite it.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f "$APP_NAME/Contents/MacOS" >/dev/null 2>&1 || break
  sleep 0.2
done

# --- install ---------------------------------------------------------------
dest="$INSTALL_DIR/$APP_NAME"
if [ -d "$dest" ]; then
  info "Replacing existing ${APP_NAME}…"
  rm -rf "$dest" 2>/dev/null || die "Could not remove old ${dest} (try: sudo rm -rf \"$dest\")."
fi
# Remove legacy bundles from before the renames so we don't keep two copies.
for legacy in "$INSTALL_DIR/Notch.app" "$INSTALL_DIR/NotchGlass.app"; do
  if [ -d "$legacy" ]; then
    info "Removing legacy $(basename "$legacy")…"
    rm -rf "$legacy" 2>/dev/null || true
  fi
done

info "Installing to ${INSTALL_DIR}…"
ditto "$src" "$dest" || die "Could not copy into ${INSTALL_DIR}."

# --- relaunch --------------------------------------------------------------
# `open` can fail with -600 (procNotFound) right after the swap: LaunchServices
# is sometimes still tearing down its record of the instance we just killed and
# refuses the path until that settles. Retry briefly, then fall back to spawning
# the binary directly — same app, just sidesteps the stale LS record.
info "Launching…"
launched=false
for _ in 1 2 3 4 5 6; do
  if open "$dest" 2>/dev/null; then launched=true; break; fi
  sleep 0.5
done
if ! $launched; then
  # An `open` that errored (-600) may still have queued its launch at LS — if
  # the app is up by now, spawning the binary on top of it is exactly the
  # double-launch. Only force-spawn when nothing actually appeared. (The app's
  # own single-instance guard in AppDelegate is the final backstop.)
  sleep 1
  if pgrep -x Notchi >/dev/null 2>&1; then
    launched=true
  else
    # Cut every tie to this shell's terminal before spawning. Leaving stdin on
    # the tty is what made this path deadly: a background-process-group child
    # that reads the terminal takes SIGTTIN and lands in state `T` (stopped) —
    # a process that exists, satisfies the pgrep check below, and never draws a
    # frame. From the outside that is exactly "the app won't open".
    nohup "$dest/Contents/MacOS/Notchi" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi
sleep 1
pgrep -x Notchi >/dev/null || die "Could not launch ${dest}."

# Being in the process table is not being running. A stopped instance (STAT `T`)
# passes the check above while the app is dead on screen, so verify the state and
# recover: resume it, and if it won't stay resumed, hand the launch back to
# LaunchServices, which parents the app to launchd instead of to this shell.
pid="$(pgrep -x Notchi | head -1)"
case "$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')" in
  T*)
    info "Instance came up suspended — resuming…"
    kill -CONT "$pid" 2>/dev/null || true
    sleep 1
    case "$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')" in
      T*)
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
        open "$dest" 2>/dev/null || true
        sleep 2
        pgrep -x Notchi >/dev/null || die "Could not launch ${dest} (stayed suspended)."
        ;;
    esac
    ;;
esac

ok "Reinstalled ${APP_NAME} from local build."
printf '%sDone.%s Hover your notch to wake it.\n' "$bold" "$reset"
