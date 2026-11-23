# shellcheck shell=bash
# Shared helpers, sourced by the scripts in bin/. They expect to run from the
# repository root.

# Loads .env into the environment.
load_env() {
	if [ ! -f .env ]; then
		echo "Error: .env is missing. Copy template.env to .env and fill it in." >&2
		exit 1
	fi
	set -a
	# shellcheck source=/dev/null
	source .env
	set +a
}

# True if the compose service is running.
service_is_running() {
	docker compose ps --status running --quiet "$1" | grep -q .
}

# Waits up to a minute for a service's healthcheck to pass.
wait_for_healthy() {
	local service=$1
	for _ in $(seq 1 30); do
		if [ "$(docker inspect -f '{{.State.Health.Status}}' "$service" 2>/dev/null)" = "healthy" ]; then
			return 0
		fi
		sleep 2
	done
	echo "Error: $service did not become healthy." >&2
	return 1
}

# Tests nginx.conf and reloads nginx gracefully.
reload_nginx() {
	docker compose exec -T nginx nginx -t -q
	docker compose exec -T nginx nginx -s reload
}

# Copies the certificate certbot obtained to the fixed names nginx.conf uses,
# then reloads nginx.
install_certificate() {
	local live="./volumes/certbot-cert/live/${DOMAIN_NAME}"
	if [ ! -f "$live/fullchain.pem" ]; then
		echo "Error: no certificate from certbot in $live." >&2
		exit 1
	fi
	mkdir -p ./volumes/nginx-cert
	cp -L "$live/fullchain.pem" "$live/privkey.pem" ./volumes/nginx-cert/
	reload_nginx
}
