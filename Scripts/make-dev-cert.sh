#!/bin/zsh
# Creates a self-signed code-signing identity, "Lumi Dev", in your login keychain, so
# every build keeps the same signature and macOS keeps its permission grants (Input Monitoring,
# Accessibility, Screen Recording) across rebuilds. Run it once; build-app.sh then uses it.
#
#   Scripts/make-dev-cert.sh
#
# It asks for your login password once, to trust the certificate for code signing. The first
# build after it may ask whether codesign can use the key: choose "Always Allow".
# Remove it later with Keychain Access (search "Lumi Dev"; delete the certificate and key).
set -euo pipefail

name="Lumi Dev"
keychain="$HOME/Library/Keychains/login.keychain-db"

# Read whole, then match: `grep -q` under pipefail can SIGPIPE `security` and read as "not found".
valid() { local ids; ids=$(security find-identity -v -p codesigning "$keychain" 2>/dev/null || true); [[ $ids == *"\"$name\""* ]] }

if valid; then
  echo "\"$name\" already exists and is valid for code signing."
  exit 0
fi

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM HUP

# Imported before but not trusted (the password prompt was cancelled): trust it again rather than
# importing a second identity with the same name.
if security find-certificate -c "$name" -p "$keychain" > "$work/existing.pem" 2>/dev/null; then
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/existing.pem"
  if valid; then echo "Trusted the existing \"$name\"."; exit 0; fi
  echo "\"$name\" exists but still isn't valid for code signing; delete it in Keychain Access and run this again." >&2
  exit 1
fi

cat > "$work/cert.cnf" <<CNF
[ req ]
default_bits = 2048
encrypt_key = no
default_md = sha256
prompt = no
distinguished_name = dn
[ dn ]
commonName = $name
[ codesign ]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# macOS's LibreSSL writes a PKCS#12 that `security import` reads (Homebrew's OpenSSL 3 would
# need -legacy).
/usr/bin/openssl req -new -newkey rsa:2048 -x509 -days 3650 -nodes -config "$work/cert.cnf" \
  -extensions codesign -out "$work/cert.pem" -keyout "$work/key.pem" 2>/dev/null
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -passout "pass:$pass" -out "$work/identity.p12"

# -T: codesign may use the key without asking every time.
security import "$work/identity.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null
# codesign refuses an untrusted self-signed identity (CSSMERR_TP_NOT_TRUSTED).
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"

if valid; then
  echo "Created \"$name\". Scripts/build-app.sh will sign with it from now on."
else
  echo "Imported \"$name\", but it isn't valid for code signing yet; check its trust in Keychain Access." >&2
  exit 1
fi
