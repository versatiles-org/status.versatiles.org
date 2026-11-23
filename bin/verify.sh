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
# The same, but without -f: for answers that aren't 200.
CURL_ANY=(curl -s --max-time 10 --resolve "${DOMAIN_NAME}:443:127.0.0.1")
failed=0

fail() {
	echo "  FAIL: $*"
	failed=1
}

echo "Verifying ${BASE} on this server..."

# Retried: `nginx -s reload` returns before the reload is done, so right after
# setup or a renewal the old workers may still serve the previous certificate.
page_ok=false
for _ in $(seq 1 10); do
	if "${CURL[@]}" -o /dev/null "$BASE/"; then
		page_ok=true
		break
	fi
	sleep 1
done
if [ "$page_ok" = "true" ]; then
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
	fail "Gatus lists $loaded endpoints, gatus/config.yaml defines $expected. Push checks only show up after their first result (bin/push/checks.sh). See: docker compose logs gatus"
fi

# The private area: closed without a session, and the login page answers.
private=$("${CURL_ANY[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/private/" || true)
if [ "$private" = "302 ${BASE}/login?next=/private/" ]; then
	echo "  ok: the private area sends visitors without a session to the login page."
else
	fail "the private area answered '$private' without a session, expected a redirect to the login page."
fi
if "${CURL[@]}" "$BASE/login" | grep -q 'name="password"'; then
	echo "  ok: the login page answers."
else
	fail "the login page doesn't answer. See: docker compose logs login"
fi

if [ "$failed" -ne 0 ]; then
	echo "Verification failed."
	exit 1
fi
echo "Verification passed."
