#!/usr/bin/env bash
# loadtest-gate.sh <compiler_image> <gateway_image> [fips] [symbol]
#
# The publish gate: build the upstream test-plugin with the freshly-built COMPILER,
# then verify it actually LOADS into the matching GATEWAY using the Gateway's own
# `tyk plugin load -s <symbol>` command (the official verification from the docs).
# This triggers plugin.Open + symbol lookup - i.e. the real ABI/version check -
# without needing redis/compose/HTTP. Non-zero exit => do NOT publish.
#
# Runs on the runner's native arch (amd64 / arm64 via native runners). ABI/dependency
# alignment is arch-independent, but we gate both architectures anyway (belt & braces).
set -euo pipefail

COMPILER="${1:?usage: loadtest-gate.sh <compiler_image> <gateway_image> [edition] [goarch] [symbol]}"
GATEWAY="${2:?usage: loadtest-gate.sh <compiler_image> <gateway_image> [edition] [goarch] [symbol]}"
EDITION="${3:-ce}"                   # ce | ee | ee-fips
GOARCH="${4:-}"                      # empty -> native host arch; else cross target (e.g. s390x)
SYMBOL="${5:-AddFooBarHeader}"       # exported symbol in the test-plugin
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PLUGDIR="$HERE/loadtest/test-plugin"

archenv=(); platform=()
if [ -n "$GOARCH" ]; then archenv=(-e GOARCH="$GOARCH"); platform=(--platform "linux/$GOARCH"); fi
echo "== gate: building test-plugin with $COMPILER (EDITION=$EDITION GOARCH=${GOARCH:-native}) =="
rm -f "$PLUGDIR"/*.so
docker run --rm -e EDITION="$EDITION" ${archenv[@]+"${archenv[@]}"} -v "$PLUGDIR:/plugin-source" "$COMPILER" plugin.so
SO="$(ls "$PLUGDIR"/plugin_*_linux_*.so | head -1)"
[ -f "$SO" ] || { echo "GATE FAIL: compiler produced no .so"; exit 1; }

echo "== gate: '$GATEWAY' (linux/${GOARCH:-host}) tyk plugin load -s $SYMBOL =="
out="$(docker run --rm ${platform[@]+"${platform[@]}"} --entrypoint /opt/tyk-gateway/tyk \
        -v "$SO:/gate-plugin.so:ro" "$GATEWAY" \
        plugin load -f /gate-plugin.so -s "$SYMBOL" 2>&1)" && rc=0 || rc=$?
echo "$out"
if [ "${rc:-1}" = "0" ] && echo "$out" | grep -q "loaded ok"; then
  echo "GATE PASS: plugin built by $COMPILER loaded into $GATEWAY (symbol $SYMBOL)"
else
  echo "GATE FAIL: plugin did not load into $GATEWAY"
  echo "$out" | grep -iE "different version|plugin.Open|error" | head -3
  exit 1
fi
