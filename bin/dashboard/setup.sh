#!/usr/bin/env bash
set -euo pipefail

# Prepares the dashboard: creates the deploy key, prints what to do with it,
# and sets up the cron job that runs update.sh every 15 minutes. Safe to run
# again. Called by bin/setup.sh and bin/update.sh; does nothing without
# DASHBOARD_REPO in .env.

cd "$(dirname "$0")/../.."
source bin/lib.sh
load_env

if [ -z "${DASHBOARD_REPO:-}" ]; then
	exit 0
fi

KEY=./volumes/dashboard-key/id_ed25519
if [ ! -f "$KEY" ]; then
	mkdir -p ./volumes/dashboard-key
	ssh-keygen -q -t ed25519 -N '' -C "dashboard@$(hostname)" -f "$KEY"
	echo "Created a deploy key for $DASHBOARD_REPO. Add it to that repo as a read-only deploy key"
	echo "(GitHub: Settings → Deploy keys → Add deploy key, without write access):"
	echo
	cat "$KEY.pub"
	echo
fi

PROJECT_DIR="$(pwd)"
CRON_CMD="*/15 * * * * cd '${PROJECT_DIR}' && ./bin/dashboard/update.sh > /dev/null 2>> /var/log/status-dashboard.log"
if crontab -l 2>/dev/null | grep -qxF "$CRON_CMD"; then
	echo "Dashboard cron job already configured."
else
	(crontab -l 2>/dev/null | grep -v "bin/dashboard/update.sh" || true; echo "$CRON_CMD") | crontab -
	echo "Dashboard cron job set (every 15 minutes)."
fi
