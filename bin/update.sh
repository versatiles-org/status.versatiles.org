#!/usr/bin/env bash
set -euo pipefail

# Pulls the latest code and applies it: new images, the nginx config and the
# Gatus config. Then runs bin/verify.sh.

cd "$(dirname "$0")/.."
source bin/lib.sh
load_env

# Only one update at a time.
exec 9>/tmp/status-update.lock
if ! flock -n 9; then
	echo "Error: another update is running." >&2
	exit 1
fi

HEAD_BEFORE=$(git rev-parse HEAD)
git pull --quiet
HEAD_AFTER=$(git rev-parse HEAD)

# bash has already read this script, so after a pull that changed it, start
# the new version. UPDATE_REEXECUTED keeps this from looping. The lock is
# released with this process and taken again by the new one.
if [ "$HEAD_BEFORE" != "$HEAD_AFTER" ] && [ -z "${UPDATE_REEXECUTED:-}" ]; then
	echo "Repository updated (${HEAD_BEFORE:0:7} → ${HEAD_AFTER:0:7}), restarting update.sh."
	exec 9>&-
	UPDATE_REEXECUTED=1 HEAD_BEFORE_UPDATE="$HEAD_BEFORE" exec "$PWD/bin/update.sh" "$@"
fi
HEAD_BEFORE=${HEAD_BEFORE_UPDATE:-$HEAD_BEFORE}

# Before `up`, so a newly generated token reaches Gatus.
ensure_push_token

# Recreates only the containers whose image or definition changed.
docker compose pull --quiet
docker compose up -d
wait_for_healthy nginx

reload_nginx

# Gatus reloads a changed config by itself, but if the new one is invalid it
# keeps the old one and only logs a warning. A restart makes an invalid config
# fail loudly here, in verify.sh, instead of going unnoticed.
if ! git diff --quiet "$HEAD_BEFORE" HEAD -- gatus/; then
	echo "The Gatus config changed, restarting Gatus."
	docker compose restart gatus
fi

# After verify.sh, which waits until Gatus is up, so it accepts the results.
./bin/verify.sh
./bin/push/setup_cron.sh
./bin/push/checks.sh
echo "Update completed."
