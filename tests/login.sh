#!/usr/bin/env bash
set -euo pipefail

# Runs the login service's tests (login/test.js) in the same Node image the
# server uses. Needs docker. Usage: tests/login.sh

cd "$(dirname "$0")/.."

IMAGE=$(sed -n 's/^ *image: *\(node:[^ ]*\).*/\1/p' compose.yaml)

docker run --rm -v "$PWD/login:/app:ro" -w /app "$IMAGE" node --test
