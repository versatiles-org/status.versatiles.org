#!/usr/bin/env bash
set -euo pipefail

# Checks that the nginx configuration loads with `nginx -t`, in the nginx image
# compose.yaml pins (or the image given) and with the same mounts, and a
# throwaway certificate where the real one is. Starts no server and needs no
# network. bin/nginx/update.sh runs it before it rolls out a new nginx image.
# (As in tiles.versatiles.org and photon-stack.)
#
# Needs docker and openssl. Usage: tests/nginx-config.sh [image]

cd "$(dirname "$0")/.."

IMAGE=${1:-$(docker compose --env-file /dev/null config --images | grep -E '^nginx:')}
echo "Testing the nginx config with $IMAGE"

CERT_DIR=$(mktemp -d)
cleanup() {
	rm -f "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem"
	rmdir "$CERT_DIR" 2>/dev/null || true
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=status.example.org -days 1 \
	-keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" 2>/dev/null
chmod a+rx "$CERT_DIR"
chmod a+r "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem"

docker run --rm -e NGINX_ENTRYPOINT_QUIET_LOGS=1 \
	-v "$PWD/nginx/nginx.stub.conf:/etc/nginx/nginx.conf:ro" \
	-v "$PWD/nginx/:/etc/nginx/repo/:ro" \
	-v "$CERT_DIR:/etc/nginx/ssl/:ro" \
	"$IMAGE" nginx -t -q

echo "nginx config OK"
