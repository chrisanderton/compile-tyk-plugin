#!/usr/bin/env bash
# resolve-gateway.sh <gateway_version>   e.g. v5.13.0
#
# The external entry point: given ONLY a Gateway version, derive everything the
# compiler build needs, straight from the published Gateway image (the single
# source of truth) - no access to Tyk's private CI required.
#
# Outputs KEY=VALUE lines to stdout and, if running in GitHub Actions, appends
# them to $GITHUB_OUTPUT:
#   GATEWAY_VERSION, GITHUB_TAG, GITHUB_SHA, GO_VERSION,
#   GO_SHA256_amd64, GO_SHA256_arm64, GO_SHA256_s390x
#
# Requires: crane, go, jq, curl, tar. (All available on a GH ubuntu runner with
# imjasonh/setup-crane + actions/setup-go.)
set -euo pipefail

VER="${1:?usage: resolve-gateway.sh <gateway_version e.g. v5.13.0>}"
GW="${GATEWAY_REPO:-tykio/tyk-gateway}:${VER}"

echo "resolving ${GW} ..." >&2

# linux architectures published for an image tag (comma-separated, sorted). Empty if absent.
# Comma-separated avoids Docker ENV/ARG space-splitting when baked into the image.
archs_of() {
  crane manifest "$1" 2>/dev/null \
    | jq -r '[.manifests[]?|select((.platform.os//"")=="linux" and (.platform.architecture//"")!="unknown")|.platform.architecture]|sort|unique|join(",")' 2>/dev/null || true
}

# Extract /opt/tyk-gateway/tyk from an image WITHOUT pulling the whole image. The binary
# lives in one large layer (direct COPY in newer images, package install in older images),
# so pull layers largest-first and stop at the one that has it. Writes <dest>/opt/tyk-gateway/tyk and
# returns non-zero if no layer yields it. (crane export would stream every layer instead.)
fetch_gw_binary() {
  local ref="$1" dest="$2" repo man cfg layers d media tar_flags
  repo="${ref%:*}"                                  # repo without :tag, for blob refs
  man="$(crane manifest --platform linux/amd64 "$ref" 2>/dev/null)" || return 1
  cfg="$(crane config --platform linux/amd64 "$ref" 2>/dev/null || printf '{}')"
  layers="$(echo "$man" | jq -r --argjson cfg "$cfg" '
    ($cfg.history // [] | map(select(.empty_layer != true))) as $history
    | [.layers // [] | to_entries[] | .value + {
        rank: (if (($history[.key].created_by // "") | test("COPY .*?/opt/tyk-gateway|dpkg -i .*tyk-gateway"; "i")) then 0 else 1 end)
      }]
    | sort_by(.rank, -(.size // 0))
    | .[] | [.digest, .mediaType] | @tsv
  ' 2>/dev/null)" || return 1
  [ -n "$layers" ] || return 1
  while IFS=$'\t' read -r d media; do
    case "$media" in
      *gzip*) tar_flags="-xzf" ;;
      *)      tar_flags="-xf" ;;
    esac
    crane blob "${repo}@${d}" 2>/dev/null | tar "$tar_flags" - -C "$dest" opt/tyk-gateway/tyk 2>/dev/null || true
    [ -s "$dest/opt/tyk-gateway/tyk" ] && return 0
  done <<< "$layers"
  return 1
}

# 1. Gateway commit - from the image's standard revision label.
CFG="$(crane config "$GW" 2>&1)" || { echo "ERROR: crane config $GW failed:" >&2; echo "$CFG" | head -3 >&2; exit 1; }
SHA="$(echo "$CFG" | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty')"
[ -n "$SHA" ] || { echo "ERROR: no org.opencontainers.image.revision label on $GW" >&2; exit 1; }

# 2. Exact Go toolchain - read from the Gateway binary itself (authoritative;
#    go.mod only carries the language version, not the patch). Use the amd64
#    image; the toolchain string is arch-independent. Pulls only the binary's layer.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fetch_gw_binary "$GW" "$TMP" || { echo "ERROR: could not fetch gateway binary from $GW (registry/auth error, or unexpected image layout)" >&2; exit 1; }
GO_VERSION="$(go version "$TMP/opt/tyk-gateway/tyk" | awk '{print $2}')"   # e.g. go1.25.10
[ -n "$GO_VERSION" ] || { echo "ERROR: could not read Go version from gateway binary" >&2; exit 1; }

# 3. Official Go tarball checksums for that exact version (no hardcoding).
GODL="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all')" || { echo "ERROR: fetching go.dev release index failed" >&2; exit 1; }
sha_for() { echo "$GODL" | jq -r --arg v "$GO_VERSION" --arg a "$1" \
  '.[]|select(.version==$v).files[]|select(.os=="linux" and .arch==$a and .kind=="archive").sha256'; }
GO_SHA256_amd64="$(sha_for amd64)"
GO_SHA256_arm64="$(sha_for arm64)"
GO_SHA256_s390x="$(sha_for s390x)"

# Per-edition architectures, read live from each edition Gateway's manifest. Data-driven so
# that if an edition GAINS an arch later (e.g. s390x EE/FIPS), it is picked up with no
# code change - the watcher rebuilds and build.sh then allows that arch for the edition.
CE_ARCHS="$(archs_of "$GW")"

# 4. FIPS variant - if a tyk-gateway-fips:<ver> exists, derive its FIPS build
#    settings from ITS binary. Handles both mechanisms automatically:
#      * newer Go: GOFIPS140=<ver> + extra build tags (e.g. ee,fips,fips140v1.0)
#      * older Go: GOEXPERIMENT=boringcrypto
FIPS_AVAILABLE=false; FIPS_GOFIPS140=""; FIPS_GOEXPERIMENT=""; FIPS_BUILD_TAG=""; FIPS_ARCHS=""
FIPSGW="${GATEWAY_FIPS_REPO:-tykio/tyk-gateway-fips}:${VER}"
if crane config "$FIPSGW" >/dev/null 2>&1; then
    FIPS_ARCHS="$(archs_of "$FIPSGW")"
  FT="$(mktemp -d)"
  fetch_gw_binary "$FIPSGW" "$FT" || true
  if [ -s "$FT/opt/tyk-gateway/tyk" ]; then
    FI="$(go version -m "$FT/opt/tyk-gateway/tyk" 2>/dev/null || true)"
    FIPS_AVAILABLE=true
    # GOFIPS140=v1.0.0-c2097c7c -> v1.0.0 (toolchain resolves the snapshot). The `|| true`
    # matters: an OLDER FIPS build uses GOEXPERIMENT=boringcrypto and has NO GOFIPS140, so
    # this grep finds nothing - without the guard, pipefail+set -e would kill the script.
    FIPS_GOFIPS140="$(echo "$FI" | grep -oE 'GOFIPS140=[^[:space:]]+' | head -1 | cut -d= -f2 | sed -E 's/-[0-9a-f]+$//' || true)"
    echo "$FI" | grep -qiE 'GOEXPERIMENT=[^[:space:]]*boringcrypto' && FIPS_GOEXPERIMENT="boringcrypto"
    # -tags=goplugin,ee,fips,fips140v1.0 -> ee,fips  (drop goplugin; drop fips140vX.Y
    # which the Go toolchain re-adds automatically whenever GOFIPS140 is set).
    FIPS_BUILD_TAG="$(echo "$FI" | grep -oE '\-tags=[^[:space:]]+' | head -1 | sed 's/-tags=//' \
      | tr ',' '\n' | grep -vE '^(goplugin|fips140v.*)$' | paste -sd, - || true)"
  fi
  rm -rf "$FT"
fi

# 5. EE variant - derive the enterprise build tags from tyk-gateway-ee (kept
#    separate from CE so we don't assume an OSS plugin is safe on EE).
EE_AVAILABLE=false; EE_BUILD_TAG=""; EE_ARCHS=""
EEGW="${GATEWAY_EE_REPO:-tykio/tyk-gateway-ee}:${VER}"
if crane config "$EEGW" >/dev/null 2>&1; then
  EE_ARCHS="$(archs_of "$EEGW")"
  ET="$(mktemp -d)"
  fetch_gw_binary "$EEGW" "$ET" || true
  if [ -s "$ET/opt/tyk-gateway/tyk" ]; then
    EI="$(go version -m "$ET/opt/tyk-gateway/tyk" 2>/dev/null || true)"
    EE_AVAILABLE=true
    EE_BUILD_TAG="$(echo "$EI" | grep -oE '\-tags=[^[:space:]]+' | head -1 | sed 's/-tags=//' \
      | tr ',' '\n' | grep -vE '^(goplugin|fips140v.*)$' | paste -sd, - || true)"
  fi
  rm -rf "$ET"
fi

emit() { echo "$1=$2"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT" || true; }
emit GATEWAY_VERSION "$VER"
emit GITHUB_TAG      "$VER"
emit GITHUB_SHA      "$SHA"
emit GO_VERSION      "$GO_VERSION"
emit GO_SHA256_amd64 "$GO_SHA256_amd64"
emit GO_SHA256_arm64 "$GO_SHA256_arm64"
emit GO_SHA256_s390x "$GO_SHA256_s390x"
emit CE_ARCHS       "$CE_ARCHS"
emit EE_AVAILABLE     "$EE_AVAILABLE"
emit EE_BUILD_TAG     "$EE_BUILD_TAG"
emit EE_ARCHS        "$EE_ARCHS"
emit FIPS_AVAILABLE   "$FIPS_AVAILABLE"
emit FIPS_GOFIPS140   "$FIPS_GOFIPS140"
emit FIPS_GOEXPERIMENT "$FIPS_GOEXPERIMENT"
emit FIPS_BUILD_TAG   "$FIPS_BUILD_TAG"
emit FIPS_ARCHS      "$FIPS_ARCHS"
