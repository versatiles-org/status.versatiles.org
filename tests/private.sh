#!/usr/bin/env bash
set -euo pipefail

# Tests the private area through nginx: starts nginx and the login service with
# this repo's configuration and a sample page for each area, then checks that
# every page is behind the login and gets the shared bar from
# nginx/private.conf, with its own link marked. Also checks that every
# /private/ location in nginx.conf uses that file, and that nginx passes the
# servers' reports to the login service (POST /report).
#
# Needs docker, curl and openssl. Usage: tests/private.sh

cd "$(dirname "$0")/.."

NODE_IMAGE=$(sed -n 's/^ *image: *\(node:[^ ]*\).*/\1/p' compose.yaml)
NGINX_IMAGE=$(sed -n 's/^ *image: *\(nginx:[^ ]*\).*/\1/p' compose.yaml)
NET=status-private-test
LOGIN=status-private-test-login
NGINX=status-private-test-nginx
PORT=18444
BASE="https://status.versatiles.org:$PORT"
CURL=(curl -sk --max-time 10 --resolve "status.versatiles.org:$PORT:127.0.0.1")
PASSWORD='test password for the private area'

TMP=$(mktemp -d)
cleanup() {
	docker rm -f "$NGINX" "$LOGIN" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	rm -f "$TMP"/ssl/fullchain.pem "$TMP"/ssl/privkey.pem "$TMP"/login/users "$TMP"/cookies \
		"$TMP"/dashboard/index.html "$TMP"/dependency-status/site/index.html \
		"$TMP"/dependency-status/site/issues/index.html "$TMP"/reports/tiles/test-job.json
	rmdir "$TMP"/ssl "$TMP"/login "$TMP"/dashboard "$TMP"/dependency-status/site/issues \
		"$TMP"/dependency-status/site \
		"$TMP"/dependency-status "$TMP"/reports/tiles "$TMP"/reports "$TMP" 2>/dev/null || true
}
trap cleanup EXIT
failed=0
fail() {
	echo "  FAIL: $*"
	failed=1
}

# Every area must take the login, the headers and the bar from private.conf.
locations=$(grep -c '^ *location /private/' nginx/nginx.conf)
includes=$(grep -c '^ *include /etc/nginx/repo/private.conf;' nginx/nginx.conf)
if [ "$locations" -eq "$includes" ]; then
	echo "  ok: all $locations /private/ locations include private.conf."
else
	fail "$locations /private/ locations in nginx.conf, but $includes include private.conf."
fi

# reports/tiles is made here, not by the login container: on Linux, a folder
# the container makes belongs to root, and cleanup couldn't empty it.
mkdir -p "$TMP/ssl" "$TMP/login" "$TMP/dashboard" "$TMP/dependency-status/site/issues" "$TMP/reports/tiles"
REPORT_TOKEN=$(openssl rand -hex 32)
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=test -days 1 \
	-keyout "$TMP/ssl/privkey.pem" -out "$TMP/ssl/fullchain.pem" 2>/dev/null
printf '<!doctype html><html><head><title>Dashboard</title></head><body><main>Dashboard</main></body></html>\n' \
	>"$TMP/dashboard/index.html"
printf '<!doctype html><html><head><title>Status</title></head><body><div id="app">Status</div></body></html>\n' \
	>"$TMP/dependency-status/site/index.html"
printf '<!doctype html><html><head><title>Issues</title></head><body><div id="app">Issues</div></body></html>\n' \
	>"$TMP/dependency-status/site/issues/index.html"

docker network create "$NET" >/dev/null
docker run --rm -v "$PWD/login:/app:ro" -v "$TMP/login:/data" -w /app "$NODE_IMAGE" node -e "
	import('./users.js').then(async (u) => {
		u.writeUsers('/data/users', new Map([['tester', await u.hashPassword('tester', process.argv[1])]]));
	});" "$PASSWORD"
docker run -d --name "$LOGIN" --network "$NET" --network-alias login \
	-v "$PWD/login:/app:ro" -v "$TMP/login:/data" -v "$TMP/reports:/reports" -w /app \
	-e LOGIN_SECRET="$(openssl rand -hex 32)" -e USERS_FILE=/data/users \
	-e REPORT_TOKEN_TILES="$REPORT_TOKEN" -e REPORTS_DIR=/reports \
	"$NODE_IMAGE" node server.js >/dev/null
docker run -d --name "$NGINX" --network "$NET" -p "127.0.0.1:$PORT:443" \
	-v "$PWD/nginx/nginx.stub.conf:/etc/nginx/nginx.conf:ro" -v "$PWD/nginx:/etc/nginx/repo:ro" \
	-v "$TMP/ssl:/etc/nginx/ssl:ro" -v "$PWD/private:/var/www/private:ro" \
	-v "$TMP/dashboard:/var/www/dashboard:ro" -v "$TMP/dependency-status:/var/www/dependency-status:ro" \
	"$NGINX_IMAGE" >/dev/null

for _ in $(seq 1 30); do
	[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/private/" || true)" = "302" ] && break
	sleep 1
done

echo "Checking the private area through nginx..."
for path in /private/ /private/dashboard/ /private/dependency-status/ /private/dependency-status/issues/ /private/bar.css; do
	code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE$path" || true)
	[ "$code" = "302" ] || fail "$path answered $code without a session, expected a redirect to the login."
done

"${CURL[@]}" -o /dev/null -c "$TMP/cookies" -H "Origin: https://status.versatiles.org" \
	--data-urlencode name=tester --data-urlencode "password=$PASSWORD" "$BASE/login"

for entry in /private/:home /private/dashboard/:dashboard /private/dependency-status/:dependencies \
	/private/dependency-status/issues/:issues; do
	path=${entry%:*} section=${entry##*:}
	page=$("${CURL[@]}" -b "$TMP/cookies" "$BASE$path" || true)
	if [ "$(grep -o 'class="vt-bar"' <<<"$page" | wc -l | tr -d ' ')" != "1" ]; then
		fail "$path doesn't have the bar exactly once."
	elif ! grep -q "data-section=\"$section\"" <<<"$page"; then
		fail "$path doesn't mark its own link ($section) in the bar."
	elif grep -o '<div class="vt-bar".*</form></div>' <<<"$page" | grep -o '<a [^>]*>' | grep -qv 'target="_self"'; then
		# Without it, VitePress' router takes over the link and nothing happens.
		fail "$path has a link in the bar without target=\"_self\"."
	else
		echo "  ok: $path has the bar, with $section marked."
	fi
done

type=$("${CURL[@]}" -b "$TMP/cookies" -o /dev/null -w '%{http_code} %{content_type}' "$BASE/private/bar.css" || true)
if [ "$type" = "200 text/css" ]; then
	echo "  ok: the bar's styles are served."
else
	fail "/private/bar.css answered '$type', expected '200 text/css'."
fi

# The cron job reports: nginx passes them to the login service, which stores
# them; login/test.js tests the details.
echo "Checking the reports through nginx..."
report() {
	"${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' "$@" "$BASE/report" || true
}
REPORT='{"job": "test-job", "exit_code": 0, "interval": 86400}'
code=$(report -d "$REPORT")
[ "$code" = "401" ] || fail "/report answered $code without a token, expected 401."
code=$(report -H "Authorization: Bearer $REPORT_TOKEN" -d "$REPORT")
if [ "$code" = "204" ] && grep -q '"server": "tiles"' "$TMP/reports/tiles/test-job.json" 2>/dev/null; then
	echo "  ok: a report with a valid token is stored."
else
	fail "/report answered $code with a valid token, expected 204 and a stored report."
fi
code=$(report -H "Authorization: Bearer $REPORT_TOKEN" -d "$(printf '{"message": "%s"}' "$(printf '%11000s' '')")")
[ "$code" = "413" ] || fail "/report answered $code for a body over 10 kB, expected nginx's 413."

if [ "$failed" -ne 0 ]; then
	echo "nginx log:"
	docker logs "$NGINX" 2>&1 | tail -20
	exit 1
fi
echo "The private area passed."
