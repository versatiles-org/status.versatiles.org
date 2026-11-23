#!/usr/bin/env bash
set -euo pipefail

# Renews the certificate if it is due, installs it for nginx and reloads nginx.
# Run weekly by cron, see setup_renewal.sh.

cd "$(dirname "$0")/../.."
source bin/lib.sh
load_env

if ! service_is_running nginx; then
	echo "Error: nginx is not running, so certbot can't prove the domain." >&2
	exit 1
fi

# --no-deps: this runs unattended from cron and must not roll out a pending
# image or config change as a side effect.
docker compose run --rm --no-deps certbot renew

install_certificate

echo "Certificate renewal checked and nginx reloaded."
