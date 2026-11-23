#!/usr/bin/env bash
set -euo pipefail

# Obtains a Let's Encrypt certificate for DOMAIN_NAME, installs it for nginx and
# sets up the weekly renewal. DNS must already point at this server.

cd "$(dirname "$0")/../.."
source bin/lib.sh
load_env

# certbot proves domain ownership through files that the running nginx serves
# from the shared certbot-www volume.
if ! service_is_running nginx; then
	echo "Error: nginx is not running, so certbot can't prove the domain." >&2
	exit 1
fi

# --no-deps: don't let compose recreate nginx or Gatus as a side effect.
docker compose run --rm --no-deps certbot certonly --webroot --webroot-path=/var/www/certbot \
	--email "${EMAIL}" --agree-tos --no-eff-email --keep-until-expiring -d "${DOMAIN_NAME}"

install_certificate
./bin/cert/setup_renewal.sh

echo "Valid certificate installed for ${DOMAIN_NAME}."
