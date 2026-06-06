#!/usr/bin/env bash
# Reproduces the prototype's end-to-end + negative validation against the lean proof
# image (= production base + Go toolchain; no gateway vendoring). Run from repo root.
# Builds base (Dockerfile.base, glibc 2.17 default) then proof on top, unless IMG is
# preset to an existing image. Override the floor with GLIBC_TARGET=2.31.
set -euo pipefail
cd "$(dirname "$0")/.."
GLIBC_TARGET="${GLIBC_TARGET:-2.17}"
# Per-floor local tags (mirrors the CI naming policy) so a 2.31 proof never reuses or
# overwrites the 2.17 proof image, and the rebuild-skip below is floor-specific.
SFX=""; [ "$GLIBC_TARGET" = "2.17" ] || SFX="-glibc${GLIBC_TARGET}"
IMG="${IMG:-tyk-plugin-compiler:proof${SFX}}"
BASE_IMG="compile-tyk-plugin-base:proof${SFX}"

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "############ BUILD: base (glibc ${GLIBC_TARGET}) + proof ############"
  docker build -f Dockerfile.base  --build-arg "GLIBC_TARGET=${GLIBC_TARGET}" -t "$BASE_IMG" .
  docker build -f Dockerfile.proof --build-arg "COMPILER_BASE_IMAGE=${BASE_IMG}" -t "$IMG" .
fi

echo "############ POSITIVE: build.sh both architectures via the real entrypoint ############"
docker run --rm \
  -v "$PWD/data:/work:ro" \
  -v "$PWD/proof/testplugin:/src:ro" \
  -e PROOF_GLIBC="$GLIBC_TARGET" \
  "$IMG" bash -c '
set -e
export TYK_GW_PATH=/go/src/github.com/TykTechnologies/tyk
export PLUGIN_SOURCE_PATH=/plugin-source
export GITHUB_TAG=v5.13.0 GITHUB_SHA=1be9931a74f4e9c62844d4ae3c0cd1510b717f46
export TYK_PLUGIN_SYSROOT_BASE=/opt/tyk/sysroots TYK_GLIBC_TARGET=$PROOF_GLIBC
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
docker run --rm -v "$PWD/data:/work:ro" -v "$PWD/proof/testplugin:/src:ro" -e PROOF_GLIBC="$GLIBC_TARGET" "$IMG" bash -c '
cp /work/validate-plugin.sh /usr/local/bin/; chmod +x /usr/local/bin/validate-plugin.sh
cd /src
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go build -buildmode=plugin -trimpath -o /tmp/native.so . 2>/dev/null
rc=0
echo "--- GLIBC too new (native build vs target $PROOF_GLIBC) ---"
EXPECT_GOARCH=arm64 MAX_GLIBC=$PROOF_GLIBC GATEWAY_GO_VERSION=go1.25.10 /usr/local/bin/validate-plugin.sh /tmp/native.so || echo "PASS: rejected (exit $?)"
echo "--- wrong arch ---"
EXPECT_GOARCH=amd64 MAX_GLIBC=2.41 /usr/local/bin/validate-plugin.sh /tmp/native.so || echo "PASS: rejected (exit $?)"
echo "--- go version mismatch ---"
EXPECT_GOARCH=arm64 MAX_GLIBC=2.41 GATEWAY_GO_VERSION=go1.24.0 /usr/local/bin/validate-plugin.sh /tmp/native.so || echo "PASS: rejected (exit $?)"
'
echo
echo "validate-proof: done"
