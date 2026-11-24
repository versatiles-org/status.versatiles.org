#!/usr/bin/env bash
set -euo pipefail

# Regenerates the dependency status page in the private area
# (/private/dependency-status/) from the public dependency-graph repo: its
# collector reads the organisation's repos with a read-only token of the
# GitHub App (see github-app/), and VitePress builds the page. Then the
# dashboard is rebuilt, which shows the same data.
#
# Cron runs this every 10 minutes with --if-due (see setup.sh in this folder).
# It then only runs when the webhook queued it, or when the last run is 6 hours
# old. So a burst of events, like a release in many repos, leads to one run.
# Without GITHUB_APP_CLIENT_ID in .env this does nothing.

cd "$(dirname "$0")/../.."
source bin/lib.sh
load_env

if [ -z "${GITHUB_APP_CLIENT_ID:-}" ]; then
	exit 0
fi

REPO=https://github.com/versatiles-org/dependency-graph.git
SRC=./volumes/dependency-status-src
OUT=./volumes/dependency-status
QUEUED=./volumes/webhook/batched/dependency-status
KEY="$PWD/volumes/github-app/private-key.pem"
MAX_AGE_MINUTES=360
IMAGE=$(sed -n 's/^ *image: *\(node:[^ ]*\).*/\1/p' compose.yaml)

if [ "${1:-}" = "--if-due" ] && [ ! -f "$QUEUED" ] && [ -f "$OUT/site/status.json" ] &&
	[ -z "$(find "$OUT/site/status.json" -mmin +"$MAX_AGE_MINUTES")" ]; then
	exit 0
fi

if [ ! -f "$KEY" ]; then
	echo "Error: the GitHub App's private key is missing at $KEY. See README.md." >&2
	exit 1
fi

# One run at a time; a second one waits, as in bin/dashboard/update.sh.
if ! command -v flock >/dev/null; then
	echo "Error: flock is missing (Debian package util-linux)." >&2
	exit 1
fi
exec 9>/tmp/status-dependency.lock
flock -w 600 9 || exit 0

# Taken now: events from here on queue the next run. A failed run queues
# itself again, so cron retries it in 10 minutes.
rm -f "$QUEUED"
trap '[ $? -eq 0 ] || { mkdir -p "$(dirname "$QUEUED")"; touch "$QUEUED"; }' EXIT

if [ ! -d "$SRC/.git" ]; then
	git clone --quiet "$REPO" "$SRC"
	changed=true
else
	before=$(git -C "$SRC" rev-parse HEAD)
	git -C "$SRC" pull --quiet --ff-only
	[ "$before" != "$(git -C "$SRC" rev-parse HEAD)" ] && changed=true || changed=false
fi

mkdir -p "$OUT"

# In the Node image of the login service. The token comes in through the
# environment, not the command line, so it doesn't show in the process list.
run_node() {
	docker run --rm -e NPM_CONFIG_UPDATE_NOTIFIER=false -e GITHUB_TOKEN -e STATUS_SITE_OUT=/out/site \
		-v "$PWD/$SRC:/src" -v "$PWD/$OUT:/out" -w /src "$IMAGE" sh -c "$1"
}
if [ "$changed" = "true" ] || [ ! -d "$SRC/node_modules" ]; then
	run_node "npm ci --no-audit --no-fund --loglevel=error"
fi

# Valid for an hour; a run takes about a minute.
GITHUB_TOKEN=$(docker run --rm -e GITHUB_APP_CLIENT_ID -v "$PWD/github-app:/app:ro" \
	-v "$KEY:/key/private-key.pem:ro" "$IMAGE" node /app/token.mjs)
export GITHUB_TOKEN

# The collector keeps what it read in $SRC/.cache/github, so the next run only
# fetches what changed.
run_node "npm run --silent sync:deps && npm run --silent build:status"
unset GITHUB_TOKEN

./bin/dashboard/update.sh
