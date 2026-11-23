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

# Adds a random value for the variable $1 to .env if it has none, and exports
# it. Used for the generated secrets: GATUS_PUSH_TOKEN (bin/push/checks.sh
# reports to Gatus with it), LOGIN_SECRET (signs the sessions of the private
# area) and WEBHOOK_SECRET (GitHub signs its webhook deliveries with it). Run
# before `docker compose up`, so the containers get them.
ensure_secret() {
	local name=$1 value
	if [ -n "${!name:-}" ]; then
		return 0
	fi
	value=$(openssl rand -hex 32)
	export "$name=$value"
	# Replace an empty entry, or append one.
	if grep -q "^${name}=" .env; then
		sed -i.bak "s/^${name}=.*/${name}=${value}/" .env
		rm -f .env.bak
	else
		printf '\n%s=%s\n' "$name" "$value" >> .env
	fi
	echo "Generated ${name} in .env."
}

# All generated secrets.
ensure_secrets() {
	ensure_secret GATUS_PUSH_TOKEN
	ensure_secret LOGIN_SECRET
	ensure_secret WEBHOOK_SECRET
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
