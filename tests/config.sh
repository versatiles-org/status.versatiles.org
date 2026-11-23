#!/usr/bin/env bash
set -euo pipefail

# Starts Gatus with gatus/config.yaml in a throwaway container, runs
# bin/push/checks.sh against it, waits until every endpoint has a result and
# prints the results.
#
# Fails if Gatus rejects the config, loads fewer endpoints than the file
# defines, or doesn't get a result for each of them, e.g. because a key in
# checks.sh doesn't match a name in the config. Failing checks are printed but
# don't fail the test, because they depend on the live services, not on this
# repo.
#
# Needs docker, curl and jq. Usage: tests/config.sh

cd "$(dirname "$0")/.."

IMAGE=$(sed -n 's/^ *image: *\(twinproduction\/gatus:[^ ]*\).*/\1/p' compose.yaml)
PORT=18080
NAME=gatus-config-test
TOKEN=test-token

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

expected=$(grep -c '^  - name:' gatus/config.yaml)

echo "Starting $IMAGE with $expected endpoints..."
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8080" \
	-v "$PWD/gatus:/config:ro" \
	--tmpfs /data \
	-e GATUS_CONFIG_PATH=/config/config.yaml \
	-e PUSHOVER_APPLICATION_TOKEN= \
	-e PUSHOVER_USER_KEY= \
	-e GATUS_PUSH_TOKEN="$TOKEN" \
	"$IMAGE" >/dev/null

for _ in $(seq 1 30); do
	curl -sf "http://127.0.0.1:$PORT/api/v1/endpoints/statuses" >/dev/null && break
	sleep 1
done
echo "Running bin/push/checks.sh against it..."
PUSH_URL="http://127.0.0.1:$PORT" GATUS_PUSH_TOKEN="$TOKEN" bin/push/checks.sh

statuses=""
for _ in $(seq 1 90); do
	if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != "true" ]; then
		echo "Error: Gatus exited. Its log:" >&2
		docker logs "$NAME" >&2
		exit 1
	fi
	statuses=$(curl -sf "http://127.0.0.1:$PORT/api/v1/endpoints/statuses" || true)
	if [ -n "$statuses" ] && [ "$(jq '[.[] | select((.results | length) > 0)] | length' <<<"$statuses")" -ge "$expected" ]; then
		break
	fi
	sleep 2
done

loaded=$(jq 'length' <<<"${statuses:-[]}")
if [ "$loaded" -ne "$expected" ]; then
	echo "Error: Gatus loaded $loaded endpoints, the config defines $expected. Its log:" >&2
	docker logs "$NAME" >&2
	exit 1
fi

checked=$(jq '[.[] | select((.results | length) > 0)] | length' <<<"$statuses")
if [ "$checked" -lt "$expected" ]; then
	echo "Error: only $checked of $expected endpoints were checked within 3 minutes." >&2
	exit 1
fi

echo ""
jq -r '.[] | .results[-1] as $r
	| "\(if $r.success then "ok  " else "FAIL" end)  \(.group) / \(.name)"
	+ ([$r.conditionResults[]? | select(.success | not) | "\n        \(.condition)"] | join(""))
	+ ([$r.errors[]? | "\n        \(.)"] | join(""))' <<<"$statuses"

echo ""
echo "Gatus accepted the config with all $expected endpoints."
