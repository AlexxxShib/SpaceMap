#!/bin/bash
set -euo pipefail

# A local development identity, shared by successive builds for this macOS user.
name="Space Map Local Development"
keychain=$(/usr/bin/security default-keychain -d user | sed 's/^ *"//; s/"$//')
if [[ -z "$keychain" || ! -f "$keychain" ]]; then
    echo "Откройте пользовательскую связку ключей и повторите настройку." >&2
    exit 1
fi
if /usr/bin/security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
    echo "Сертификат $name уже есть в связке ключей."
    exit 0
fi

umask 077
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
/usr/bin/openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -subj "/CN=$name" -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=critical,codeSigning' \
    -keyout "$scratch/key" -out "$scratch/cert"
/usr/bin/openssl rsa -in "$scratch/key" -out "$scratch/key.rsa"
cat "$scratch/cert" "$scratch/key.rsa" > "$scratch/identity.pem"
/usr/bin/security import "$scratch/identity.pem" -f pemseq -k "$keychain" -x -T /usr/bin/codesign
echo "Создан сертификат $name для локальных сборок."
