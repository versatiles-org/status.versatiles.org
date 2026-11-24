#!/usr/bin/env bash
set -euo pipefail

# Runs the tests of the GitHub App token script (github-app/test.js) in the
# same Node image the server uses. Needs docker. Usage: tests/github-app.sh

cd "$(dirname "$0")/.."

IMAGE=$(sed -n 's/^ *image: *\(node:[^ ]*\).*/\1/p' compose.yaml)

docker run --rm -v "$PWD/github-app:/app:ro" -w /app "$IMAGE" node --test
