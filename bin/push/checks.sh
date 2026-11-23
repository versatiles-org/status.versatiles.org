#!/usr/bin/env bash
set -euo pipefail

# Runs the checks Gatus can't run itself, because they read response headers or
# compare dates, and reports each result to its Gatus external endpoint (see
# external-endpoints in gatus/config.yaml). Run every 10 minutes by cron, see
# setup_cron.sh.
#
# A check whose source doesn't answer reports nothing: Gatus' HTTP checks alert
# on that already, and the heartbeat catches it if it lasts.
#
# Needs curl and jq. Usage: bin/push/checks.sh
# tests/config.sh sets PUSH_URL and GATUS_PUSH_TOKEN instead of using .env.

cd "$(dirname "$0")/../.."
source bin/lib.sh

if [ -z "${PUSH_URL:-}" ]; then
	load_env
	PUSH_URL="https://${DOMAIN_NAME}"
	PUSH_CURL=(curl -sf --max-time 10 --resolve "${DOMAIN_NAME}:443:127.0.0.1")
else
	PUSH_CURL=(curl -sf --max-time 10)
fi
: "${GATUS_PUSH_TOKEN:?GATUS_PUSH_TOKEN is not set}"

TILES=https://tiles.versatiles.org
DOWNLOAD=https://download.versatiles.org
MAX_PLANET_AGE_DAYS=180
GRACE_DAYS=7

# Reports a result. $1: the endpoint's key, $2: an error message, empty for success.
report() {
	local key=$1 error=${2:-} query
	if [ -z "$error" ]; then
		query="success=true"
	else
		query="success=false&error=$(jq -rn --arg s "$error" '$s | @uri')"
	fi
	echo "$key: ${error:-ok}"
	# Retried for about half a minute: right after bin/update.sh restarted Gatus,
	# nginx answers 502 until Gatus is up.
	"${PUSH_CURL[@]}" --retry 10 --retry-delay 3 --retry-all-errors \
		-X POST -H "Authorization: Bearer ${GATUS_PUSH_TOKEN}" \
		"${PUSH_URL}/api/v1/endpoints/${key}/external?${query}" >/dev/null
}

# Checks the content type of URLs that answer with 200.
# $1: the endpoint's key, $2: the expected type, then the URLs.
check_content_type() {
	local key=$1 expected=$2 url result code type errors="" answered=false
	shift 2
	for url in "$@"; do
		result=$(curl -s --max-time 20 -o /dev/null -w '%{http_code} %{content_type}' "$url" || true)
		code=${result%% *}
		type=${result#* }
		[ "$code" = "200" ] || continue
		answered=true
		if [ "$type" != "$expected" ]; then
			errors="${errors}${url} is served as '${type}', expected '${expected}'. "
		fi
	done
	if [ "$answered" = "true" ]; then
		report "$key" "${errors% }"
	fi
}

check_content_type content_map-tiles:-vector-tile-content-type application/vnd.mapbox-vector-tile \
	"$TILES/tiles/osm/5/17/10"

# Zoom 5 comes from the tile server's local copy, zoom 17 from the CDN.
check_content_type content_satellite:-tile-content-type image/webp \
	"$TILES/tiles/satellite/5/17/10" \
	"$TILES/tiles/satellite/17/70420/42986"

# The newest planet: the highest date in the osm-vector.YYYYMMDD.versatiles
# file names on the download page.
latest=""
age=""
if page=$(curl -sf --max-time 20 "$DOWNLOAD/"); then
	latest=$(grep -oE 'osm-vector\.[0-9]{8}\.versatiles' <<<"$page" | grep -oE '[0-9]{8}' | sort | tail -1 || true)
	if [ -z "$latest" ]; then
		report map-data-age_download:-newest-planet "No osm-vector.YYYYMMDD.versatiles found on $DOWNLOAD/."
	else
		age=$(jq -n --arg d "$latest" '(now - ($d | strptime("%Y%m%d") | mktime)) / 86400 | floor')
		if [ "$age" -gt "$MAX_PLANET_AGE_DAYS" ]; then
			report map-data-age_download:-newest-planet "The newest planet, $latest, is $age days old (limit: $MAX_PLANET_AGE_DAYS)."
		else
			report map-data-age_download:-newest-planet ""
		fi
	fi
fi

# The planet the tile server serves, by the date it was built. The release is
# named after the same date.
if [ -n "$latest" ] && meta=$(curl -sf --max-time 20 "$TILES/tiles/osm/meta.json"); then
	built=$(jq -r '."planetiler:buildtime" // "" | .[0:10] | gsub("-"; "")' <<<"$meta")
	if [ -z "$built" ]; then
		report map-data-age_map-tiles:-newest-planet-served "$TILES/tiles/osm/meta.json has no planetiler:buildtime."
	elif [ "$built" -ge "$latest" ] || [ "$age" -le "$GRACE_DAYS" ]; then
		report map-data-age_map-tiles:-newest-planet-served ""
	else
		report map-data-age_map-tiles:-newest-planet-served "tiles.versatiles.org serves the planet built $built, but $latest was released $age days ago. Run bin/update.sh there."
	fi
fi
