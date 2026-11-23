#!/usr/bin/env bash
set -euo pipefail

# First-time setup on a new server, after .env is filled in and DNS points at
# the server. Safe to run again: every step skips what is already done.

cd "$(dirname "$0")/.."
source bin/lib.sh
load_env

if [ "${EMAIL:-}" = "name@example.org" ] || [ -z "${EMAIL:-}" ]; then
	echo "Error: set EMAIL in .env to a real address for the Let's Encrypt account." >&2
	exit 1
fi
if [ -z "${PUSHOVER_APPLICATION_TOKEN:-}" ] || [ -z "${PUSHOVER_USER_KEY:-}" ]; then
	echo "Warning: the Pushover keys in .env are empty, so no alerts will be sent."
fi

ensure_secrets

mkdir -p ./volumes/gatus-data ./volumes/certbot-www ./volumes/certbot-cert ./volumes/nginx-cert ./volumes/login ./volumes/dashboard

# nginx needs some certificate to start, and must be running for certbot.
./bin/cert/create_dummy.sh

docker compose pull --quiet
docker compose up -d
wait_for_healthy nginx

./bin/cert/create_valid.sh
# Before verify.sh: Gatus lists a push check only once it got a result, and
# verify.sh expects every check from the config.
./bin/push/setup_cron.sh
./bin/push/checks.sh
# The dashboard is optional (DASHBOARD_REPO in .env) and needs its deploy key
# on GitHub first, so a failure here only warns.
./bin/dashboard/setup.sh
./bin/dashboard/update.sh || echo "Warning: the dashboard could not be generated. Is the deploy key added to the repo?"
./bin/verify.sh

echo "Setup completed. Add a user for the private area with: ./bin/user.sh add <name>"
