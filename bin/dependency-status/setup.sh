#!/usr/bin/env bash
set -euo pipefail

# Sets up the cron job that runs update.sh every 10 minutes with --if-due (see
# there). Safe to run again. Called by bin/setup.sh and bin/update.sh; does
# nothing without GITHUB_APP_CLIENT_ID in .env.

cd "$(dirname "$0")/../.."
source bin/lib.sh
load_env

if [ -z "${GITHUB_APP_CLIENT_ID:-}" ]; then
	exit 0
fi

if [ ! -f ./volumes/github-app/private-key.pem ]; then
	echo "Warning: copy the GitHub App's private key to volumes/github-app/private-key.pem, see README.md."
fi

PROJECT_DIR="$(pwd)"
CRON_CMD="*/10 * * * * cd '${PROJECT_DIR}' && ./bin/dependency-status/update.sh --if-due > /dev/null 2>> /var/log/status-dependency.log"
if crontab -l 2>/dev/null | grep -qxF "$CRON_CMD"; then
	echo "Dependency status cron job already configured."
else
	(crontab -l 2>/dev/null | grep -v "bin/dependency-status/update.sh" || true; echo "$CRON_CMD") | crontab -
	echo "Dependency status cron job set (every 10 minutes when due)."
fi
