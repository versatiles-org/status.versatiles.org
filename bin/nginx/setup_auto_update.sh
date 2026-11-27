#!/usr/bin/env bash
set -euo pipefail

# Sets up a daily cron job (4:30am) that runs bin/nginx/update.sh, which rolls
# out a new nginx image, and reports the run to the private dashboard
# (bin/cron/run.sh). 4:30 keeps clear of the certificate renewal (Sundays at
# 3am). Safe to run again: it replaces an existing entry instead of adding a
# second. bin/setup.sh and bin/update.sh run it.

cd "$(dirname "$0")/../.."
PROJECT_DIR="$(pwd)"
CRON_CMD="30 4 * * * cd '${PROJECT_DIR}' && ./bin/cron/run.sh nginx-update 86400 ./bin/nginx/update.sh >> /var/log/nginx-update.log 2>&1"

if crontab -l 2>/dev/null | grep -qxF "$CRON_CMD"; then
	echo "nginx update cron job already configured."
else
	(crontab -l 2>/dev/null | grep -v "bin/nginx/update.sh" || true; echo "$CRON_CMD") | crontab -
	echo "nginx update cron job set (daily at 4:30am)."
fi
