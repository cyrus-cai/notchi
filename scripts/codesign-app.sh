#!/usr/bin/env bash
#
# Notchi — the single code-signing implementation. CI (release.yml) and the local
# dev loop (reinstall.sh) both call this, so the shipped bundle and the locally
# installed one can never drift apart in signing identity, entitlements, or
# hardened-runtime state.
#
#   scripts/codesign-app.sh [--debug] <path-to-.app>
#
# Why this exists at all: macOS TCC (the privacy database behind the
# Accessibility grant) does not remember "this app". It stores the app's
# *designated requirement* and re-evaluates it on every launch. An ad-hoc
# signature's DR is a bare `cdhash H"..."` — the hash of one exact binary — so
# every rebuild and every release produces a requirement the stored grant no
# longer satisfies, and the Accessibility permission silently stops working
# (the toggle still *looks* enabled in System Settings, which is what makes it
# so confusing). Signing with a real certificate makes the DR
# `identifier "..." and certificate leaf H"..."`, which is stable across builds
# forever. See scripts/make-signing-cert.sh for creating that certificate.
#
# Environment:
#   NOTCHI_SIGN_IDENTITY  identity to sign with (default: "Notchi Code Signing")
#   NOTCHI_SIGN_KEYCHAIN  keychain to search for it (default: the search list)
#   NOTCHI_SIGN_REQUIRED  1 ⇒ hard-fail when the identity is missing, instead of
#                         falling back to ad-hoc. CI sets this; the local dev
#                         loop does not, so reinstall.sh keeps working on a
#                         machine that has not created the certificate yet.
set -euo pipefail

cd "$(dirname "$0")/.."

ENTITLEMENTS="NotchGlass/Resources/NotchGlass.entitlements"
IDENTITY="${NOTCHI_SIGN_IDENTITY:-Notchi Code Signing}"
REQUIRED="${NOTCHI_SIGN_REQUIRED:-0}"

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
info() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok()   { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s!%s %s\n' "$yellow" "$reset" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

# --- args ------------------------------------------------------------------
DEBUG_BUILD=false
APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) DEBUG_BUILD=true; shift ;;
    -*)      die "Unknown option: $1" ;;
    *)       APP="$1"; shift ;;
  esac
done
[ -n "$APP" ] || die "Usage: scripts/codesign-app.sh [--debug] <path-to-.app>"
[ -d "$APP" ] || die "Not a bundle: $APP"
[ -f "$ENTITLEMENTS" ] || die "Entitlements file missing: $ENTITLEMENTS"

# Built as a plain string rather than an array: macOS still ships bash 3.2,
# where expanding an empty array under `set -u` is itself an unbound-variable
# error. There is nothing to word-split badly here — the path comes from our own
# workflow — so the simple form is also the portable one.
keychain_args=""
[ -n "${NOTCHI_SIGN_KEYCHAIN:-}" ] && keychain_args="--keychain $NOTCHI_SIGN_KEYCHAIN"

# --- resolve the identity --------------------------------------------------
# `find-identity -v` lists only identities that are actually usable for signing.
# A self-signed certificate that was imported but never *trusted* for code
# signing shows up under plain `find-identity` as CSSMERR_TP_NOT_TRUSTED and is
# invisible here — which is exactly the failure we want to catch loudly, since
# codesign's own message for it ("no identity found") gives no hint why.
identity_available() {
  security find-identity -v -p codesigning ${NOTCHI_SIGN_KEYCHAIN:+"$NOTCHI_SIGN_KEYCHAIN"} 2>/dev/null \
    | grep -qF "\"$IDENTITY\""
}

if identity_available; then
  sign_as="$IDENTITY"
elif [ "$REQUIRED" = "1" ]; then
  die "Signing identity \"$IDENTITY\" not found (or not trusted for code signing).
    Create it with: scripts/make-signing-cert.sh
    In CI, check the SIGNING_CERT_P12 / SIGNING_CERT_PASSWORD secrets."
else
  warn "Signing identity \"$IDENTITY\" not found — falling back to ad-hoc."
  warn "Ad-hoc signatures make the Accessibility permission drop on every build."
  warn "Run scripts/make-signing-cert.sh once to fix that permanently."
  sign_as="-"
fi

# --- entitlements ----------------------------------------------------------
# Debug builds additionally need get-task-allow so a debugger can attach; under
# the hardened runtime that entitlement is the only thing permitting it.
# Entitlements do NOT participate in the designated requirement, so Debug and
# Release still resolve to the same DR and therefore share one TCC grant — which
# is the whole point of signing the dev-loop build with the same certificate.
ent_file="$ENTITLEMENTS"
tmp_ent=""
if $DEBUG_BUILD; then
  tmp_ent="$(mktemp -t notchi-ent).plist"
  cp "$ENTITLEMENTS" "$tmp_ent"
  /usr/libexec/PlistBuddy -c \
    "Add :com.apple.security.get-task-allow bool true" "$tmp_ent" >/dev/null 2>&1 || true
  ent_file="$tmp_ent"
  # Preserve the failing status explicitly: an EXIT trap whose last command
  # succeeds can otherwise mask a `die` and report success to the caller.
  trap 'rc=$?; rm -f "$tmp_ent"; exit $rc' EXIT
fi

# --- sign ------------------------------------------------------------------
# Hardened runtime: ON for Release, OFF for Debug.
#
# It is applied to Release because the project asks for it
# (ENABLE_HARDENED_RUNTIME = YES) and the shipped builds only lacked it because
# the old release step re-signed without the flag, silently dropping it together
# with the entitlements. Release is safe: a single Mach-O, no third-party
# libraries, no microphone/camera APIs.
#
# It is NOT applied to Debug, because the hardened runtime turns on *library
# validation* and Xcode injects two of its own dylibs into a Debug bundle
# (Notchi.debug.dylib for the incremental-build stub, __preview.dylib for
# SwiftUI previews). Re-signing the bundle leaves those with a different signing
# identity than the main executable, and dyld then refuses to map them:
#
#   Library not loaded: @rpath/Notchi.debug.dylib
#   Reason: ... mapping process and mapped file (non-platform) have different
#           Team IDs
#
# — i.e. the app builds, signs, verifies, installs, and then will not start.
# This is also why Xcode's own "Sign to Run Locally" leaves Debug builds without
# the runtime flag. Entitlements do not affect the designated requirement, and
# neither does this, so Debug and Release still share one TCC grant.
if $DEBUG_BUILD; then
  hardened_args=""
else
  hardened_args="--options runtime"
fi
[ "${NOTCHI_SIGN_HARDENED:-1}" = "0" ] && hardened_args=""

# Sign nested Mach-O code inside-out, before the bundle that contains it — a
# signature over the bundle covers the nested files' *hashes*, so signing the
# outside first would immediately invalidate it. (`--deep` would do this too but
# Apple deprecated it, and it applies the main executable's options to nested
# code, which is wrong: entitlements belong only to the main executable.)
nested="$(find "$APP" -type f \( -name '*.dylib' -o -name '*.so' \) 2>/dev/null || true)"
if [ -n "$nested" ]; then
  info "Signing nested code…"
  printf '%s\n' "$nested" | while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    printf '    %s\n' "$(basename "$lib")"
    # shellcheck disable=SC2086
    codesign --force --sign "$sign_as" --timestamp=none $keychain_args "$lib"
  done
fi

info "Signing $(basename "$APP") as ${dim}${sign_as}${reset}…"
# shellcheck disable=SC2086  # both *_args are intentionally word-split (may be empty)
codesign --force \
         --sign "$sign_as" \
         --entitlements "$ent_file" \
         --timestamp=none \
         $hardened_args \
         $keychain_args \
         "$APP"

# --- verify ----------------------------------------------------------------
# Every check below is a hard gate. A bundle that fails any of them must never
# reach a user: unlike an unsigned app (which still launches once quarantine is
# cleared), a *broken* signature is reported by macOS as "the app is damaged"
# and cannot be opened at all.
info "Verifying…"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# The entitlements must have survived the signature — losing
# com.apple.security.automation.apple-events breaks Notes integration and
# losing …personal-information.calendars breaks Reminders, both silently and
# only under the hardened runtime.
for key in com.apple.security.automation.apple-events \
           com.apple.security.personal-information.calendars; do
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "$key" \
    || die "Entitlement lost during signing: $key"
done

# `codesign -d -r-` prints the requirement as `# designated => ...` (with the
# leading comment marker) on stderr-mixed output — hence 2>&1 and no anchor.
dr="$(codesign -d -r- "$APP" 2>&1 | grep 'designated' || true)"
[ -n "$dr" ] || die "Could not read the designated requirement back from $APP."
printf '    %s\n' "$dr"

if [ "$sign_as" != "-" ]; then
  # The regression guard. If this ever reads `cdhash H"..."` again, the build
  # fell back to ad-hoc somewhere and every user's Accessibility grant is about
  # to break — fail the build rather than ship it.
  case "$dr" in
    *"certificate leaf"*) ok "Designated requirement is certificate-based (stable across builds)." ;;
    *) die "Designated requirement is not certificate-based — signing fell back to ad-hoc.
    Shipping this would reset every user's Accessibility permission." ;;
  esac
  if [ -n "$hardened_args" ]; then
    codesign -dvvv "$APP" 2>&1 | grep -q 'flags=.*runtime' \
      || die "Hardened runtime flag missing after signing."
  fi
fi

# A bundle whose nested libraries carry a different signing identity than the
# main executable verifies cleanly here and then fails to launch under library
# validation ("different Team IDs"). Signing inside-out above makes the
# identities match by construction; assert it rather than trust it, since the
# failure mode is an app that installs successfully and simply never starts.
if [ -n "$nested" ]; then
  main_auth="$(codesign -dvvv "$APP" 2>&1 | grep -E '^(Authority|Signature)=' | head -1)"
  printf '%s\n' "$nested" | while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    lib_auth="$(codesign -dvvv "$lib" 2>&1 | grep -E '^(Authority|Signature)=' | head -1)"
    [ "$lib_auth" = "$main_auth" ] || die "Nested library signed with a different
    identity than the main executable — the app would install and then not start.
      $(basename "$lib"): $lib_auth
      main executable: $main_auth"
  done
fi

ok "Signed and verified: $APP"
