#!/usr/bin/env bash
#
# Notchi — create the self-signed code-signing certificate. Run this ONCE.
#
#   ./scripts/make-signing-cert.sh
#
# WHY
# ---
# macOS TCC stores the Accessibility grant against the app's *designated
# requirement*, not against the app. An ad-hoc signature ("codesign --sign -")
# has the DR `cdhash H"<hash of this exact binary>"`, so every rebuild and every
# release invalidates the grant: the toggle keeps looking enabled in System
# Settings while AXIsProcessTrusted() quietly returns false.
#
# Signing with a certificate changes the DR to
# `identifier "com.notchglass.app" and certificate leaf H"<cert fingerprint>"`,
# which does not depend on the binary at all. Rebuild as often as you like — the
# grant survives.
#
# WHAT THIS DOES NOT DO
# ---------------------
# It does not improve Gatekeeper. A self-signed certificate is exactly as
# untrusted to Gatekeeper as no certificate: `spctl --assess` still rejects, and
# users who download the .zip manually still have to approve it in System
# Settings → Privacy & Security. Only a paid Developer ID + notarization fixes
# that. This script solves the permission-drop problem, nothing else.
#
# THE CERTIFICATE IS A RELEASE-CRITICAL SECRET
# --------------------------------------------
# The DR pins the certificate's fingerprint. If the certificate is ever lost or
# replaced, the DR changes and EVERY user has to grant Accessibility again. Back
# up the exported .p12 somewhere durable and treat it like a signing key.
set -euo pipefail

cd "$(dirname "$0")/.."

CN="${NOTCHI_SIGN_IDENTITY:-Notchi Code Signing}"
DAYS="${NOTCHI_CERT_DAYS:-7300}"          # ~20 years; expiry only blocks *new* signing
OUT_DIR="${NOTCHI_CERT_OUT:-$HOME/.notchi-signing}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
info() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok()   { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s!%s %s\n' "$yellow" "$reset" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only."

# --- refuse to silently replace an existing identity -----------------------
# Re-issuing the certificate changes the leaf fingerprint, which changes the DR,
# which resets every user's Accessibility grant. That must be a deliberate act.
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$CN\""; then
  ok "A usable code-signing identity named \"$CN\" already exists."
  security find-identity -v -p codesigning | grep -F "\"$CN\"" | sed 's/^/    /'
  echo
  warn "Not regenerating. Re-issuing would change the certificate fingerprint,"
  warn "change the designated requirement, and reset every user's Accessibility"
  warn "permission. To deliberately replace it, delete the old identity from"
  warn "Keychain Access first."
  exit 0
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# macOS's `security import` only accepts the legacy PKCS#12 encryption. OpenSSL
# 3 defaults to the modern one and needs -legacy; LibreSSL (/usr/bin/openssl)
# already emits the old format and has no such flag.
OPENSSL="$(command -v openssl)"
legacy_args=()
if "$OPENSSL" version | grep -q '^OpenSSL 3'; then
  legacy_args=(-legacy -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES)
fi

# --- generate --------------------------------------------------------------
info "Generating a self-signed code-signing certificate (${DAYS} days)…"
cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CN
[v3]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$work/key.pem" -out "$work/cert.pem" \
  -days "$DAYS" -config "$work/cert.cnf" 2>/dev/null \
  || die "Certificate generation failed."

P12_PASSWORD="$(uuidgen)"
"$OPENSSL" pkcs12 -export \
  -out "$OUT_DIR/notchi-signing.p12" \
  -inkey "$work/key.pem" -in "$work/cert.pem" \
  -passout "pass:$P12_PASSWORD" -name "$CN" \
  "${legacy_args[@]}" \
  || die "PKCS#12 export failed."
chmod 600 "$OUT_DIR/notchi-signing.p12"
cp "$work/cert.pem" "$OUT_DIR/notchi-signing.cer"
printf '%s\n' "$P12_PASSWORD" > "$OUT_DIR/notchi-signing.password"
chmod 600 "$OUT_DIR/notchi-signing.password"

"$OPENSSL" x509 -in "$work/cert.pem" -noout -subject -dates | sed 's/^/    /'

# --- import into the login keychain ----------------------------------------
info "Importing into your login keychain…"
security import "$OUT_DIR/notchi-signing.p12" \
  -k "$LOGIN_KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign \
  || die "Import failed."

# Without this, codesign can hold the key but macOS prompts for the keychain
# password on every single signing operation.
info "Authorising codesign to use the key (may prompt for your login password)…"
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: -s -k "" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 \
  || warn "Could not set the key partition list non-interactively — macOS will
    prompt once the first time you sign. Click \"Always Allow\"."

# --- trust it for code signing ---------------------------------------------
# This is the step that is easy to miss: an imported-but-untrusted self-signed
# certificate is reported by `security find-identity` as CSSMERR_TP_NOT_TRUSTED
# and codesign refuses it with the unhelpful message "no identity found".
info "Trusting the certificate for code signing (will prompt for authorisation)…"
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$LOGIN_KEYCHAIN" "$OUT_DIR/notchi-signing.cer" \
  || die "Could not add trust settings. Without them codesign will refuse this
    certificate with \"no identity found\"."

# --- verify ----------------------------------------------------------------
if ! security find-identity -v -p codesigning | grep -qF "\"$CN\""; then
  die "The identity still is not usable for code signing. Open Keychain Access,
    find \"$CN\", and set \"Code Signing\" to \"Always Trust\"."
fi
ok "Identity is usable:"
security find-identity -v -p codesigning | grep -F "\"$CN\"" | sed 's/^/    /'

# --- CI secrets ------------------------------------------------------------
echo
info "GitHub Actions secrets — add these to the repo (Settings → Secrets and variables → Actions):"
echo
printf '  %sSIGNING_CERT_PASSWORD%s\n' "$bold" "$reset"
printf '    %s\n' "$P12_PASSWORD"
echo
printf '  %sSIGNING_CERT_P12%s  (base64 of the .p12)\n' "$bold" "$reset"
printf '    %sRun:%s gh secret set SIGNING_CERT_P12 < "%s"\n' \
  "$dim" "$reset" "$OUT_DIR/notchi-signing.p12.base64"
base64 < "$OUT_DIR/notchi-signing.p12" > "$OUT_DIR/notchi-signing.p12.base64"
chmod 600 "$OUT_DIR/notchi-signing.p12.base64"
echo
cat <<EOF
${bold}Files written to $OUT_DIR${reset}
    notchi-signing.p12             the identity — ${red}back this up${reset}
    notchi-signing.password        its password — back this up too
    notchi-signing.p12.base64      paste-ready for the GitHub secret
    notchi-signing.cer             the public certificate

${bold}Back these up now.${reset} The designated requirement pins this certificate's
fingerprint. Losing it means the next release changes the DR and every user has
to grant Accessibility again.

${bold}Next:${reset}
    gh secret set SIGNING_CERT_P12 < "$OUT_DIR/notchi-signing.p12.base64"
    gh secret set SIGNING_CERT_PASSWORD --body "\$(cat "$OUT_DIR/notchi-signing.password")"
    ./scripts/reinstall.sh
EOF
