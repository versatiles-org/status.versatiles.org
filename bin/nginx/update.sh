#!/usr/bin/env bash
set -euo pipefail

# Rolls out a new nginx image, and nothing else. Runs daily from cron (see
# setup_auto_update.sh), so that a security fix in nginx, which reaches the
# official image the day nginx releases it, is live within a day instead of
# waiting for the next push. The same procedure as bin/nginx/update.sh in
# tiles.versatiles.org and photon-stack.
#
# It runs unattended, so it only acts when it is safe to:
#   - Nothing happens unless a newer image arrived under the same tag, or if
#     compose.yaml describes nginx differently from the running container: that
#     change belongs to bin/update.sh.
#   - Before the switch, the nginx config must load in the new image
#     (tests/nginx-config.sh). If not, nginx keeps running the previous image.
#   - The switch costs about 3 seconds of refused connections.
#   - Afterwards nginx must be healthy and answer HTTPS with the real
#     certificate. If not, it is recreated from the previous image.
#   - Afterwards the running nginx must be the newest release of a line that
#     nginx.org still maintains (bin/nginx/check_version.sh). That catches the
#     tag in compose.yaml going stale, which the rollout alone can't see.
# The other services are never touched (--no-deps).
#
# Exits 0 when nginx is up to date or was updated, 1 when something needs a
# look: see /var/log/nginx-update.log, and the private dashboard.

cd "$(dirname "$0")/../.."
source bin/lib.sh
load_env

log() { echo "$(date -u +%FT%TZ) $*"; }

# Fails when the nginx that runs is behind nginx.org, see check_version.sh.
check_version() {
	local running
	running=$(docker compose exec -T nginx nginx -v 2>&1 | sed -n 's#^nginx version: nginx/##p' || true)
	./bin/nginx/check_version.sh "$running"
}

# The lock of bin/update.sh, so a deploy and this never replace nginx at the
# same time. A deploy takes a minute or two; this waits up to ten.
exec 9>/tmp/status-update.lock
if ! flock -w 600 9; then
	log "Error: bin/update.sh has been running for ten minutes; trying again tomorrow."
	exit 1
fi

if ! service_is_running nginx; then
	log "Error: nginx is not running. Not starting it unattended: run bin/update.sh."
	exit 1
fi
cid=$(docker compose ps -q nginx)

# The running container must match compose.yaml (the hash compose stored when
# it created the container). Otherwise a recreate would also roll out that
# definition change, unattended.
want_hash=$(docker compose config --hash nginx | awk '{print $2}')
have_hash=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.config-hash" }}' "$cid")
if [ "$want_hash" != "$have_hash" ]; then
	log "Error: compose.yaml describes nginx differently from the running container. Run bin/update.sh."
	exit 1
fi

image_ref=$(docker inspect -f '{{.Config.Image}}' "$cid")
old_image=$(docker inspect -f '{{.Image}}' "$cid")

docker compose pull --quiet nginx
new_image=$(docker image inspect -f '{{.Id}}' "$image_ref")

if [ "$new_image" = "$old_image" ]; then
	log "nginx is up to date ($image_ref)."
	check_version || exit 1
	exit 0
fi
log "A new $image_ref arrived: ${old_image:7:12} → ${new_image:7:12}."

# Point the tag back at the image nginx runs, so that nothing (this script, or
# bin/update.sh) picks up a new image that was not rolled out.
restore_old_tag() { docker tag "$old_image" "$image_ref"; }

recreate_nginx() {
	log "Recreating nginx: new connections are refused for a few seconds."
	docker compose up --detach --no-deps --force-recreate --timeout 3 nginx
}

# Healthy, and serving HTTPS with the real certificate: the healthcheck alone
# only asks for /healthz on port 80. nginx answers /favicon.ico itself (a
# redirect), so this works while Gatus is down. Gives up after about two minutes.
nginx_works() {
	local code
	for _ in $(seq 1 40); do
		code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
			--resolve "$DOMAIN_NAME:443:127.0.0.1" "https://$DOMAIN_NAME/favicon.ico" 2>/dev/null || true)
		if [ "$(docker inspect -f '{{.State.Health.Status}}' nginx 2>/dev/null)" = healthy ] && [ "$code" = 302 ]; then
			return 0
		fi
		sleep 3
	done
	return 1
}

if ! ./tests/nginx-config.sh "$image_ref"; then
	restore_old_tag
	log "Error: the nginx config does not load in the new image. nginx keeps running the previous one."
	log "       Fix the config before the next bin/update.sh, which would roll the new image out."
	exit 1
fi

if ! recreate_nginx || ! nginx_works; then
	log "Error: nginx does not work with the new image. Rolling back to the previous image."
	restore_old_tag
	if recreate_nginx && nginx_works; then
		log "Rolled back: nginx runs the previous image again."
	else
		log "Error: nginx does not work with the previous image either. It needs a look now."
	fi
	exit 1
fi

log "nginx update completed: nginx runs the new image and answers HTTPS."
check_version || exit 1
