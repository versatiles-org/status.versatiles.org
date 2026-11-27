#!/usr/bin/env bash
set -euo pipefail

# Regenerates the dashboard in the private area (/private/dashboard/). Run
# every 15 minutes by cron (see setup.sh in this folder) and after each push to
# the dashboard repo by the webhook (see bin/webhook).
#
# The dashboard comes from a private repo, named by DASHBOARD_REPO in .env and
# cloned with a read-only deploy key. That repo's `npm run dashboard -- --out
# <dir>` writes static pages, which nginx serves behind the login. Nothing of
# that repo is stored in this one. Without DASHBOARD_REPO this does nothing.

cd "$(dirname "$0")/../.."
source bin/lib.sh
load_env

if [ -z "${DASHBOARD_REPO:-}" ]; then
	exit 0
fi

SRC=./volumes/dashboard-src
OUT=./volumes/dashboard
# Absolute: git runs ssh inside the clone (git -C), where a relative path fails.
KEY="$PWD/volumes/dashboard-key/id_ed25519"
IMAGE=$(sed -n 's/^ *image: *\(node:[^ ]*\).*/\1/p' compose.yaml)

if [ ! -f "$KEY" ]; then
	echo "Error: no deploy key. Run bin/dashboard/setup.sh first." >&2
	exit 1
fi
export GIT_SSH_COMMAND="ssh -i '$KEY' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

# One run at a time. A second one waits instead of giving up: a push may come
# in after the running one has pulled. Checked first, so a missing flock fails
# loudly instead of skipping every run.
if ! command -v flock >/dev/null; then
	echo "Error: flock is missing (Debian package util-linux)." >&2
	exit 1
fi
exec 9>/tmp/status-dashboard.lock
flock -w 600 9 || exit 0

if [ ! -d "$SRC/.git" ]; then
	git clone --quiet "$DASHBOARD_REPO" "$SRC"
	changed=true
else
	before=$(git -C "$SRC" rev-parse HEAD)
	git -C "$SRC" pull --quiet --ff-only
	[ "$before" != "$(git -C "$SRC" rev-parse HEAD)" ] && changed=true || changed=false
fi

mkdir -p "$OUT"

# In the same Node image as the login service. Dependencies only after a change,
# since npm ci takes longer than the generation itself.
run_node() {
	docker run --rm -e NPM_CONFIG_UPDATE_NOTIFIER=false -v "$PWD/$SRC:/src" -v "$PWD/$OUT:/out" \
		-v "$PWD/volumes/dependency-status:/status:ro" -v "$PWD/volumes/reports:/reports:ro" \
		-w /src "$IMAGE" sh -c "$1"
}
if [ "$changed" = "true" ] || [ ! -d "$SRC/node_modules" ]; then
	run_node "npm ci --no-audit --no-fund --loglevel=error"
fi
# The repo status from this server's dependency status (bin/dependency-status),
# once there is one; until then, the dashboard's own default.
STATUS_ARG=""
if [ -f ./volumes/dependency-status/site/status.json ]; then
	STATUS_ARG="--status /status/site/status.json"
fi
# The servers' cron job reports, which the login service stores (login/report.js).
# Created by docker when the login service starts, so it's there on a set-up server.
REPORTS_ARG=""
if [ -d ./volumes/reports ]; then
	REPORTS_ARG="--reports /reports"
fi

run_node "npm run --silent dashboard -- --out /out $STATUS_ARG $REPORTS_ARG"
