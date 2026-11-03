#!/bin/bash
# One-time: create a self-signed code-signing identity in the login keychain so
# the System Audio Recording grant survives rebuilds (ad-hoc signatures change
# cdhash on every build and TCC re-prompts).
#
# Uses /usr/bin/openssl (LibreSSL) on purpose: Homebrew OpenSSL 3 exports
# PKCS#12 with AES/PBKDF2, which `security import` rejects.
set -euo pipefail

NAME="${SIGN_IDENTITY:-AudioControl Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl

# --- Exact-CN existence check (find-certificate -c is a substring match) ----
check_existing() {
  local pems tmpdir n=0 valid=0 expired=0
  tmpdir="$(mktemp -d)"
  pems="$(security find-certificate -a -p -c "$NAME" "$KEYCHAIN" 2>/dev/null || true)"
  if [[ -n "$pems" ]]; then
    # Split concatenated PEMs into one file each.
    echo "$pems" | awk -v dir="$tmpdir" '
      /-----BEGIN CERTIFICATE-----/ { n++; f = dir "/" n ".pem" }
      { if (f) print > f }
      /-----END CERTIFICATE-----/ { close(f); f = "" }'
    for f in "$tmpdir"/*.pem; do
      [[ -e "$f" ]] || continue
      local cn
      cn="$($OPENSSL x509 -in "$f" -noout -subject -nameopt RFC2253 | sed -E 's/^subject= ?//')"
      if [[ "$cn" == "CN=$NAME" ]]; then
        n=$((n+1))
        if $OPENSSL x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1; then
          valid=$((valid+1))
        else
          expired=$((expired+1))
          local sha
          sha="$($OPENSSL x509 -in "$f" -noout -fingerprint -sha1 | sed -E 's/.*=//; s/://g')"
          echo "An EXPIRED certificate with CN '$NAME' exists (SHA-1 $sha)." >&2
          echo "Delete it first, then rerun:" >&2
          echo "  security delete-certificate -Z $sha \"$KEYCHAIN\"" >&2
        fi
      fi
    done
  fi
  rm -rf "$tmpdir"
  if (( expired > 0 )); then exit 2; fi
  if (( valid > 0 )); then
    echo "Identity '$NAME' already exists and is valid. Nothing to do."
    exit 0
  fi
}
check_existing

# --- Generate in a temp dir outside the repo; key material never touches it --
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3_code
prompt = no
[dn]
CN = $NAME
[v3_code]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF

$OPENSSL req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" >/dev/null 2>&1

P12PASS="$(head -c 24 /dev/urandom | base64)"
$OPENSSL pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/cert.p12" -name "$NAME" -passout "pass:$P12PASS"

echo "Importing identity '$NAME' into login keychain..."
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" -f pkcs12 \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign >/dev/null

echo "Marking certificate as trusted for code signing (macOS may ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# Let codesign use the key without a GUI prompt. Needs the keychain password;
# skip if not provided (you'll get a one-time "Always Allow" dialog instead).
if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
else
  echo "KEYCHAIN_PASSWORD not set: the first codesign will show an 'Always Allow' dialog once."
fi

echo "Done. Expires: $($OPENSSL x509 -in "$WORK/cert.pem" -noout -enddate | sed 's/notAfter=//')"
security find-identity -v -p codesigning | grep -F "\"$NAME\"" || \
  echo "warning: identity not listed as valid yet; trust settings may need a moment or a re-run."
