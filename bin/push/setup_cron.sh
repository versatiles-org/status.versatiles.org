#!/usr/bin/env bash
set -euo pipefail

# Sets up the cron job that runs checks.sh every 10 minutes. Called by
# bin/setup.sh and bin/update.sh.

cd "$(dirname "$0")/../.."

PROJECT_DIR="$(pwd)"
# Only errors of the script itself go to the log. The results are in Gatus.
CRON_CMD="*/10 * * * * cd '${PROJECT_DIR}' && ./bin/push/checks.sh > /dev/null 2>> /var/log/status-checks.log"

if crontab -l 2>/dev/null | grep -qxF "$CRON_CMD"; then
	echo "Push checks cron job already configured."
else
	# Replace any existing entry, e.g. one pointing to an old project path.
	(crontab -l 2>/dev/null | grep -v "bin/push/checks.sh" || true; echo "$CRON_CMD") | crontab -
	echo "Push checks cron job set (every 10 minutes)."
fi
