# Compiling plugins for a custom / self-built Gateway

## The rule
A Go plugin is **ABI-bound to one specific Gateway build** - same Go version, same
module graph, same build tags/flags, same FIPS/edition. The published
`compile-tyk-plugin:vX.Y.Z` images match the **official tykio Gateways**. If you build
your **own** Gateway (a fork, custom dependencies, extra build tags, a private patch,
a different Go version...), you need a compiler built from **your** Gateway's source -
the official compiler will produce plugins that fail `plugin.Open` against your build.

Good news: the whole design is **source-agnostic**. `Dockerfile.release` vendors
whatever Gateway source you give it as the build context, and the stable
`Dockerfile.base` (toolchain + glibc sysroots) is reused unchanged. So you build a
custom compiler with the *same* files, just pointed at your source.

## Three ways to do it

### 1. Build a compiler from your Gateway source (most common)
```bash
# your Gateway fork at the exact ref you build/run
git clone https://github.com/myorg/tyk && cd tyk && git checkout my-ref

docker build -f /path/to/compile-tyk-plugin/Dockerfile.release \
  --build-arg BASE_IMAGE=ghcr.io/<you>/compile-tyk-plugin-base:latest \
  --build-arg GO_VERSION=go1.25.10 \
  --build-arg GO_SHA256_amd64=<sha> --build-arg GO_SHA256_arm64=<sha> \
  --build-arg GITHUB_SHA=$(git rev-parse HEAD) \
  --build-arg GITHUB_TAG=my-ref \
  -t my-compile-tyk-plugin:my-ref .          # build context = your Gateway checkout
```
- `GO_VERSION` must equal the Go your Gateway is built with (`go version -m your-gateway-binary`).
- If your Gateway uses extra build tags (e.g. `ee`, custom): `--build-arg BUILD_TAG=ee,whatever`.
- For FIPS: `--build-arg FIPS_AVAILABLE=true --build-arg FIPS_GOFIPS140=v1.0.0 --build-arg FIPS_BUILD_TAG=ee,fips` (then `-e FIPS=1` at use).
- The base image is generic - pull the published one or build it yourself once (`Dockerfile.base`).

### 2. Auto-derive from your published Gateway image
If you publish your custom Gateway image, the resolver reads the Go version + commit
(and FIPS params) straight from it - no manual lookup:
```bash
GATEWAY_REPO=myorg/my-tyk-gateway \
GATEWAY_FIPS_REPO=myorg/my-tyk-gateway-fips \
  ./scripts/resolve-gateway.sh my-ref
# emits GO_VERSION / GITHUB_SHA / GO_SHA256_* / FIPS_* to feed into the build above.
```
(Your image must carry the standard `org.opencontainers.image.revision` label and a
Go-built `/opt/tyk-gateway/tyk` binary - both true for images built the Tyk way.)

### 3. Fully local (no published base)
Build the base once, then the release layer on top - two commands, no registry:
```bash
docker build -f /path/to/compile-tyk-plugin/Dockerfile.base -t ctp-base:local /path/to/compile-tyk-plugin
docker build -f /path/to/compile-tyk-plugin/Dockerfile.release \
  --build-arg BASE_IMAGE=ctp-base:local \
  --build-arg GO_VERSION=... [other args as in option 1] \
  -t my-compile-tyk-plugin:my-ref .          # build context = your Gateway checkout
```
`task build:base` then `task build:release VERSION=<v> TYK_SRC=<checkout>` wraps this.

## Use it via CI (the workflow is fork-aware)
`.github/workflows/build.yml` takes optional inputs so the same pipeline serves a
custom Gateway:
- `gateway_image_repo` (default `tykio/tyk-gateway`) - image to resolve + gate against,
- `source_repo` (default `TykTechnologies/tyk`) and `source_ref` (default = the version) -
  the Gateway source to vendor.

Point them at your fork/registry and dispatch as usual.

## Validate against YOUR Gateway
Always verify against the *same* build you'll run:
```bash
# lightweight ABI check (load + symbol):
docker run --rm --entrypoint /opt/tyk-gateway/tyk -v "$PWD/plugin.so:/p.so:ro" \
  myorg/my-tyk-gateway:my-ref plugin load -f /p.so -s MySymbol

# full request-path check:
./scripts/e2e-compose.sh my-compile-tyk-plugin:my-ref myorg/my-tyk-gateway:my-ref
```

## Caveats
- The glibc **sysroot** target (2.31) must be <= your Gateway runtime's glibc - true for
  any normal Linux base; if your runtime is unusually old, lower `GLIBC_TARGET` and
  rebuild the base.
- A **different Go version** is fine - pass it; the base has no Go baked, the release
  layer installs whatever you specify.
- **musl** custom runtime (e.g. Alpine-based fork) would need a musl sysroot/toolchain -
  out of scope here (the design targets glibc Gateways).
