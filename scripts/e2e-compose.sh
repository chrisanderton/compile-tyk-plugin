#!/usr/bin/env bash
# e2e-compose.sh <compiler_image> <gateway_image> [edition] [arch]
#
# FULL end-to-end HTTP test (heavier than the publish gate): build the test-plugin
# with COMPILER, run GATEWAY + redis + httpbin via docker compose, send a request and
# assert the plugin actually executed (injects `Foo: Bar`). Use this to confirm
# runtime *behaviour*; the publish gate (scripts/loadtest-gate.sh) only verifies
# load+symbol via `tyk plugin load`.
#
#   [arch] (optional): cross-build + run that arch under QEMU (e.g. amd64 / s390x).
#   Omitted => native host arch. The plugin is mounted at the Gateway's expanded name
#   plugin_<ver>_linux_<arch>.so - Tyk rewrites the apidef path to that BEFORE trying the
#   literal plugin.so, and that literal-path fallback is NOT honoured on every arch (s390x).
#
# Examples:
#   ./scripts/e2e-compose.sh <you>/compile-tyk-plugin:v5.13.0 tykio/tyk-gateway:v5.13.0
#   ./scripts/e2e-compose.sh <you>/compile-tyk-plugin:v5.13.0 tykio/tyk-gateway:v5.13.0 ce amd64
#   ./scripts/e2e-compose.sh <you>/compile-tyk-plugin:v5.13.0 tykio/tyk-gateway-fips:v5.13.0 ee-fips
#   # custom gateway image:
#   ./scripts/e2e-compose.sh my-compiler:dev myorg/my-tyk-gateway:1.0.0
set -uo pipefail

COMPILER="${1:?usage: e2e-compose.sh <compiler_image> <gateway_image> [edition] [arch]}"
GATEWAY="${2:?usage: e2e-compose.sh <compiler_image> <gateway_image> [edition] [arch]}"
EDITION="${3:-ce}"                   # ce | ee | ee-fips
ARCH="${4:-}"                        # empty = native host arch; else cross target (amd64/s390x/...)
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PLUGDIR="$HERE/loadtest/test-plugin"

archenv=(); [ -n "$ARCH" ] && archenv=(-e GOARCH="$ARCH")
echo "== build test-plugin with $COMPILER (EDITION=$EDITION, target=${ARCH:-native}) =="
rm -f "$PLUGDIR"/*.so
docker run --rm -e EDITION="$EDITION" ${archenv[@]+"${archenv[@]}"} -v "$PLUGDIR:/plugin-source" "$COMPILER" plugin.so
SO="$(ls "$PLUGDIR"/plugin_*_linux_*.so 2>/dev/null | head -1)"
[ -f "$SO" ] || { echo "E2E FAIL: compiler produced no .so"; exit 1; }
# Mount at the EXACT name the Gateway expands the apidef path to (plugin_<ver>_linux_<arch>.so),
# passed into the compose file via $PLUGIN_FILE - do NOT rely on the literal plugin.so fallback.
export PLUGIN_FILE="$(basename "$SO")"
echo "   built $PLUGIN_FILE"

# Pick the matching compose file: a per-arch one (platform-pinned, emulated) if present,
# else the default (native). The plugin's arch must match the Gateway's platform.
cd "$HERE/loadtest"
compose="docker-compose.yml"
[ -n "$ARCH" ] && [ -f "docker-compose.${ARCH}.yml" ] && compose="docker-compose.${ARCH}.yml"
echo "== run $GATEWAY (${ARCH:-native}) + redis + httpbin via $compose =="
export GATEWAY_IMAGE="$GATEWAY"
trap 'docker compose -f "$compose" down --remove-orphans >/dev/null 2>&1 || true' EXIT
docker compose -f "$compose" up -d --force-recreate

ok=0
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/hello 2>/dev/null)" = "200" ] && { ok=1; break; }
  sleep 3
done
[ "$ok" = "1" ] || { echo "E2E FAIL: gateway not healthy"; docker compose -f "$compose" logs gw | tail -30; exit 1; }

# Retry the plugin route to ride out the API-registration race (notably under emulation).
for i in $(seq 1 20); do
  resp="$(curl -s http://localhost:8080/goplugin/headers 2>/dev/null || true)"
  if echo "$resp" | jq -e '.headers.Foo == "Bar"' >/dev/null 2>&1; then
    echo "E2E PASS: $GATEWAY (${ARCH:-native}) served the request with plugin-injected Foo: Bar"
    exit 0
  fi
  sleep 3
done
echo "E2E FAIL: plugin did not inject the header"
echo "response: $(echo "$resp" | head -c 400)"
docker compose -f "$compose" logs gw 2>&1 | grep -iE "plugin|error" | tail -20
exit 1
