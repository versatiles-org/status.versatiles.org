#!/usr/bin/env bash
set -euo pipefail

# Runs the jobs the webhook queued in volumes/webhook (see login/webhook.js).
# Started by the systemd path unit from setup.sh in this folder whenever that
# directory isn't empty. Output goes to the journal: journalctl -u status-webhook

cd "$(dirname "$0")/../.."

QUEUE=./volumes/webhook

# Each job file is removed before its job starts, so a push during the run
# queues it again, and systemd starts this once more afterwards.
run_job() {
	local job=$1
	shift
	if [ -f "$QUEUE/$job" ]; then
		rm -f "$QUEUE/$job"
		echo "Running $job."
		"$@"
	fi
}

run_job dashboard ./bin/dashboard/update.sh
