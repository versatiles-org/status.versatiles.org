#!/usr/bin/env bash
set -euo pipefail

# Installs the systemd units that run bin/webhook/run.sh as soon as the webhook
# queues a job in volumes/webhook. Safe to run again. Called by bin/setup.sh and
# bin/update.sh.
#
# The webhook itself is set up on GitHub, in the settings of the repo whose
# pushes should trigger a job (only DASHBOARD_REPO so far):
#   Payload URL:  https://<DOMAIN_NAME>/webhook
#   Content type: application/json
#   Secret:       WEBHOOK_SECRET from .env
#   Events:       Just the push event

cd "$(dirname "$0")/../.."

if ! command -v systemctl >/dev/null; then
	echo "Error: systemd is missing; the webhook's jobs need it." >&2
	exit 1
fi

PROJECT_DIR="$(pwd)"
UNITS=/etc/systemd/system
mkdir -p ./volumes/webhook

# DirectoryNotEmpty also triggers again after the service ends if a job was
# queued in the meantime. The trigger limit stops a loop if a file can't be
# removed.
PATH_UNIT="[Unit]
Description=Start the jobs queued by the status.versatiles.org webhook

[Path]
DirectoryNotEmpty=${PROJECT_DIR}/volumes/webhook
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
