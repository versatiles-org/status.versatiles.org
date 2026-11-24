#!/usr/bin/env bash
set -euo pipefail

# Installs the systemd units that run bin/webhook/run.sh as soon as the webhook
# queues a job in volumes/webhook/now. Safe to run again. Called by bin/setup.sh and
# bin/update.sh.
#
# The webhooks themselves are set up on GitHub, in the settings of each repo
# whose events should trigger a job:
#   Payload URL:  https://<DOMAIN_NAME>/webhook
#   Content type: application/json
#   Secret:       WEBHOOK_SECRET from .env
#   Events:       Pushes, Releases, Issues, Pull requests, Repositories and
#                 Workflow runs.
# Best as one webhook for the whole organisation (its settings → Webhooks):
# the dependency status needs events from every public repo, and the same
# deliveries cover DASHBOARD_REPO and UPDATE_REPO. The receiver decides what
# each event triggers.

cd "$(dirname "$0")/../.."

if ! command -v systemctl >/dev/null; then
	echo "Error: systemd is missing; the webhook's jobs need it." >&2
	exit 1
fi

PROJECT_DIR="$(pwd)"
UNITS=/etc/systemd/system
mkdir -p ./volumes/webhook/now ./volumes/webhook/batched

# DirectoryNotEmpty also triggers again after the service ends if a job was
# queued in the meantime. The trigger limit stops a loop if a file can't be
# removed.
PATH_UNIT="[Unit]
Description=Start the jobs queued by the status.versatiles.org webhook

[Path]
DirectoryNotEmpty=${PROJECT_DIR}/volumes/webhook/now
TriggerLimitIntervalSec=60
TriggerLimitBurst=10

[Install]
WantedBy=multi-user.target"

SERVICE_UNIT="[Unit]
Description=Jobs queued by the status.versatiles.org webhook

[Service]
Type=oneshot
WorkingDirectory=${PROJECT_DIR}
ExecStart=${PROJECT_DIR}/bin/webhook/run.sh"

changed=false
install_unit() {
	local file=$1 content=$2
	if [ "$(cat "$file" 2>/dev/null)" != "$content" ]; then
		printf '%s\n' "$content" > "$file"
		changed=true
	fi
}
install_unit "$UNITS/status-webhook.path" "$PATH_UNIT"
install_unit "$UNITS/status-webhook.service" "$SERVICE_UNIT"

if [ "$changed" = "true" ]; then
	systemctl daemon-reload
	systemctl enable --now status-webhook.path
	systemctl restart status-webhook.path
	echo "Webhook units installed. Set up the webhook on GitHub as described in bin/webhook/setup.sh."
else
	systemctl enable --now --quiet status-webhook.path
	echo "Webhook units already installed."
fi
