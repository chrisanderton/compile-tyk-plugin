#!/usr/bin/env bash
# e2e-compose.sh <compiler_image> <gateway_image> [fips]
#
# FULL end-to-end HTTP test (heavier than the publish gate): build the test-plugin
# with COMPILER, run GATEWAY + redis + httpbin via docker compose, send a request and
# assert the plugin actually executed (injects `Foo: Bar`). Use this to confirm
# runtime *behaviour*; the publish gate (scripts/loadtest-gate.sh) only verifies
# load+symbol via `tyk plugin load`.
#
# Examples:
#   ./scripts/e2e-compose.sh <you>/compile-tyk-plugin:v5.13.0 tykio/tyk-gateway:v5.13.0
#   ./scripts/e2e-compose.sh <you>/compile-tyk-plugin:v5.13.0 tykio/tyk-gateway-ee:v5.13.0   ee
#   ./scripts/e2e-compose.sh <you>/compile-tyk-plugin:v5.13.0 tykio/tyk-gateway-fips:v5.13.0 ee-fips
#   # custom gateway image:
#   ./scripts/e2e-compose.sh my-compiler:dev myorg/my-tyk-gateway:1.0.0
set -euo pipefail

COMPILER="${1:?usage: e2e-compose.sh <compiler_image> <gateway_image> [edition]}"
GATEWAY="${2:?usage: e2e-compose.sh <compiler_image> <gateway_image> [edition]}"
EDITION="${3:-ce}"                   # ce | ee | ee-fips
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PLUGDIR="$HERE/loadtest/test-plugin"

echo "== build test-plugin with $COMPILER (EDITION=$EDITION) =="
rm -f "$PLUGDIR"/*.so
docker run --rm -e EDITION="$EDITION" -v "$PLUGDIR:/plugin-source" "$COMPILER" plugin.so
cp "$PLUGDIR"/plugin_*_linux_*.so "$PLUGDIR/plugin.so"

echo "== run $GATEWAY + redis + httpbin and exercise the request path =="
cd "$HERE/loadtest"
export GATEWAY_IMAGE="$GATEWAY"
trap 'docker compose down --remove-orphans >/dev/null 2>&1 || true' EXIT
docker compose up -d --force-recreate

ok=0
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/hello 2>/dev/null)" = "200" ] && { ok=1; break; }
  sleep 3
done
[ "$ok" = "1" ] || { echo "E2E FAIL: gateway not healthy"; docker compose logs gw | tail -30; exit 1; }

resp="$(curl -s http://localhost:8080/goplugin/headers 2>/dev/null || true)"
if echo "$resp" | jq -e '.headers.Foo == "Bar"' >/dev/null 2>&1; then
  echo "E2E PASS: $GATEWAY served the request with plugin-injected Foo: Bar"
else
  echo "E2E FAIL: plugin did not inject the header"
  echo "response: $(echo "$resp" | head -c 400)"
  docker compose logs gw 2>&1 | grep -iE "plugin|error" | tail -20
  exit 1
fi
