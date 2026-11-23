#!/usr/bin/env bash
set -euo pipefail

# Checks that this server serves the status page: through nginx on this machine
# (independent of DNS), with a valid certificate, and with every endpoint from
# gatus/config.yaml loaded in Gatus.

cd "$(dirname "$0")/.."
source bin/lib.sh
load_env

BASE="https://${DOMAIN_NAME}"
CURL=(curl -sf --max-time 10 --resolve "${DOMAIN_NAME}:443:127.0.0.1")
failed=0

fail() {
	echo "  FAIL: $*"
	failed=1
}

echo "Verifying ${BASE} on this server..."

if "${CURL[@]}" -o /dev/null "$BASE/"; then
	echo "  ok: the page answers with a valid certificate."
else
	fail "the page doesn't answer over HTTPS, or its certificate is invalid."
fi

days=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN_NAME" 2>/dev/null |
	openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
if [ -n "$days" ]; then
	left=$((($(date -d "$days" +%s) - $(date +%s)) / 86400))
	if [ "$left" -lt 14 ]; then
		fail "the certificate expires in $left days."
	else
		echo "  ok: the certificate is valid for $left more days."
	fi
else
	fail "could not read the certificate."
fi

# Gatus may still be starting after a restart.
expected=$(grep -c '^  - name:' gatus/config.yaml)
loaded=0
for _ in $(seq 1 30); do
	loaded=$("${CURL[@]}" "$BASE/api/v1/endpoints/statuses" | jq 'length' 2>/dev/null || true)
	loaded=${loaded:-0}
	[ "$loaded" -ge "$expected" ] && break
	sleep 2
done
if [ "$loaded" -eq "$expected" ]; then
	echo "  ok: Gatus has loaded all $expected endpoints."
else
	fail "Gatus has loaded $loaded endpoints, gatus/config.yaml defines $expected. See: docker compose logs gatus"
fi

if [ "$failed" -ne 0 ]; then
	echo "Verification failed."
	exit 1
fi
echo "Verification passed."
