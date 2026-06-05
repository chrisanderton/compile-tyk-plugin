#!/usr/bin/env bash
# Reproduces the prototype's end-to-end + negative validation against the lean
# proof image (sysroot + toolchain, no gateway vendoring). Run from repo root.
#   docker build -f Dockerfile.proof -t tyk-plugin-compiler:proof .
#   ./scripts/validate-proof.sh
set -euo pipefail
cd "$(dirname "$0")/.."
IMG="${IMG:-tyk-plugin-compiler:proof}"

echo "############ POSITIVE: build.sh both architectures via the real entrypoint ############"
docker run --rm \
  -v "$PWD/data:/work:ro" \
  -v "$PWD/proof/testplugin:/src:ro" \
  "$IMG" bash -c '
set -e
export TYK_GW_PATH=/go/src/github.com/TykTechnologies/tyk
export PLUGIN_SOURCE_PATH=/plugin-source
export GITHUB_TAG=v5.13.0 GITHUB_SHA=1be9931a74f4e9c62844d4ae3c0cd1510b717f46
export TYK_PLUGIN_SYSROOT_BASE=/opt/tyk/sysroots TYK_GLIBC_TARGET=2.31
mkdir -p $TYK_GW_PATH $PLUGIN_SOURCE_PATH
printf "module github.com/TykTechnologies/tyk\n\ngo 1.25\n" > $TYK_GW_PATH/go.mod   # stub gateway
cp /src/* $PLUGIN_SOURCE_PATH/
cp /work/build.sh /build.sh; cp /work/validate-plugin.sh /usr/local/bin/
chmod +x /build.sh /usr/local/bin/validate-plugin.sh
( cd $TYK_GW_PATH && /build.sh plugin.so "" linux amd64 )
( cd $TYK_GW_PATH && /build.sh plugin.so "" linux arm64 )
ls -la $PLUGIN_SOURCE_PATH/*.so
'

echo
echo "############ NEGATIVE: validator must reject bad artifacts ############"
docker run --rm -v "$PWD/data:/work:ro" -v "$PWD/proof/testplugin:/src:ro" "$IMG" bash -c '
cp /work/validate-plugin.sh /usr/local/bin/; chmod +x /usr/local/bin/validate-plugin.sh
cd /src
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go build -buildmode=plugin -trimpath -o /tmp/native.so . 2>/dev/null
rc=0
echo "--- GLIBC too new (native build vs target 2.31) ---"
EXPECT_GOARCH=arm64 MAX_GLIBC=2.31 GATEWAY_GO_VERSION=go1.25.10 /usr/local/bin/validate-plugin.sh /tmp/native.so || echo "PASS: rejected (exit $?)"
echo "--- wrong arch ---"
EXPECT_GOARCH=amd64 MAX_GLIBC=2.41 /usr/local/bin/validate-plugin.sh /tmp/native.so || echo "PASS: rejected (exit $?)"
echo "--- go version mismatch ---"
EXPECT_GOARCH=arm64 MAX_GLIBC=2.41 GATEWAY_GO_VERSION=go1.24.0 /usr/local/bin/validate-plugin.sh /tmp/native.so || echo "PASS: rejected (exit $?)"
'
echo
echo "validate-proof: done"
