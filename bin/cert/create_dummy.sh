#!/usr/bin/env bash
set -euo pipefail

# Creates a self-signed certificate, so nginx can start before certbot has
# obtained a real one. Does nothing if a certificate is already in place.

cd "$(dirname "$0")/../.."
source bin/lib.sh
load_env

if [ -f ./volumes/nginx-cert/fullchain.pem ]; then
	echo "A certificate is already in place."
	exit 0
fi

mkdir -p ./volumes/nginx-cert
openssl req -nodes -new -x509 -days 30 -subj "/CN=${DOMAIN_NAME}" \
	-keyout ./volumes/nginx-cert/privkey.pem \
	-out ./volumes/nginx-cert/fullchain.pem

echo "Dummy certificate created for ${DOMAIN_NAME}."
