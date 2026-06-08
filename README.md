# compile-tyk-plugin

A prebuilt, low-CVE, **multi-arch** Docker image set for compiling Tyk Go plugins.
Use it as a drop-in replacement for the official `tyk-plugin-compiler`: same
`docker run` shape, same output naming, but with native amd64/arm64 images and a
focused plugin-builder base.

> **Community / unofficial.** Not affiliated with or supported by Tyk. It consumes only
> public Tyk artifacts.

For normal use, you do **not** build this repository. Pick the prebuilt image tag that
matches your Gateway version, then run it against your plugin source.

What it gives you:
- **Prebuilt per Gateway release** - tags such as `v5.13.0` already contain the exact
  Go toolchain, Gateway source, dependency graph, edition flags, and FIPS settings for
  that Gateway.
- **Drop-in compiler interface** - mount your plugin source at `/plugin-source` and pass
  the output name, just like `tykio/tyk-plugin-compiler`.
- **Native amd64 + arm64 images** - no `--platform=linux/amd64` needed on Apple Silicon
  or arm64 Linux runners.
- **Docker Hardened Image base** - hardened, minimal, continuously patched. In our
  measurements this means far fewer CVE-scanner findings (about 85-90% fewer
  CRITICAL/HIGH).
- **One image, many targets** - cross-compiles amd64/arm64/s390x and builds for the
  **CE / EE / EE-FIPS** editions, all selected with a flag.
- **Old-glibc CGO compatibility as an isolated link sysroot** - plugins link against a
  pinned glibc-2.17 floor (RHEL 7 / CentOS 7 ABI) for broad portability, while the image
  itself stays modern and small.

It is purpose-built for compiling plugins. The official `tyk-plugin-compiler` is a
general-purpose Gateway release builder that does more than compile plugins, so a direct
package-count or CVE comparison is not apples-to-apples; the figures above reflect a base
chosen specifically for the plugin-compilation job.

Examples below use Docker Hub image `chrisanderton/compile-tyk-plugin`. Replace that
with your internal mirror if you copy the images into a private registry.

---

## Pick a prebuilt image
Use the compiler tag that matches the Gateway version and base variant you want.
Docker automatically pulls the native amd64 or arm64 image for your host.

| Compiler tag | Use when |
|---|---|
| `chrisanderton/compile-tyk-plugin:vX.Y.Z` | Default choice. DHI-based, amd64+arm64 image, cross-targets amd64/arm64/s390x. |
| `chrisanderton/compile-tyk-plugin:vX.Y.Z-wolfi` | Wolfi/Chainguard base. Native amd64/arm64 only; no s390x cross target. |
| `chrisanderton/compile-tyk-plugin:vX.Y.Z-YYYYMMDD` | Immutable snapshot of the default tag for reproducible builds. |
| `chrisanderton/compile-tyk-plugin:vX.Y.Z-wolfi-YYYYMMDD` | Immutable snapshot of the Wolfi tag. |

`vX.Y.Z` is your Tyk Gateway version, for example `v5.13.0`.

Advanced glibc-floor variants are documented in [`docs/glibc-targets.md`](docs/glibc-targets.md).

```bash
docker pull chrisanderton/compile-tyk-plugin:v5.13.0
```

Published-version policy and retention are documented in [`SUPPORT.md`](SUPPORT.md).

## Quick start
From your plugin source directory:

```bash
docker run --rm -v "$PWD:/plugin-source" \
  chrisanderton/compile-tyk-plugin:vX.Y.Z my-plugin.so
# -> writes my-plugin_vX.Y.Z_linux_<goarch>.so into the mounted directory
```
Same interface as the official compiler - only the image name changes.

### Arguments (entrypoint `/build.sh`)
| Pos | Name | Meaning |
|---|---|---|
| 1 | `plugin_name` | output `.so` name (required), e.g. `my-plugin.so` |
| 2 | `plugin_id` / `build_id` | optional; isolates the build & gives load-time uniqueness |
| 3 | `GOOS` | optional; default `linux` |
| 4 | `GOARCH` | optional; default = host arch |

### Environment variables
- **Edition:** `EDITION=ce` (default) `| ee | ee-fips` (`FIPS=1` = alias for `ee-fips`).
- **Target arch:** `GOARCH=amd64|arm64|s390x` (or positional arg 4).
- Preserved from the official compiler: `PLUGIN_SOURCE_PATH`, `PLUGIN_BUILD_PATH`,
  `BUILD_TAG`, `GO_GET`, `GO_TIDY`, `DEBUG`, `GOFIPS140`.
- Added: `VALIDATE=0` to skip post-build validation; `GOPROXY`/`GOSUMDB` for air-gapped
  builds (below).

Advanced sysroot settings are documented in [`docs/glibc-targets.md`](docs/glibc-targets.md).

Output naming matches the official convention: `{name}_{Gw-version}_{GOOS}_{GOARCH}.so`.

## Architectures & cross-compilation
One image carries glibc sysroots + cross toolchains for **amd64, arm64, s390x**, so any
target builds via `GOARCH` regardless of host:
```bash
docker run --rm -e GOARCH=arm64 -v "$PWD:/plugin-source" \
  chrisanderton/compile-tyk-plugin:vX.Y.Z my-plugin.so

docker run --rm -e GOARCH=s390x -v "$PWD:/plugin-source" \
  chrisanderton/compile-tyk-plugin:vX.Y.Z my-plugin.so  # big-endian, CE only
```
The compiler image itself is published amd64 + arm64 (native on each); s390x is a
cross target. Prefer the native image of the target arch for CGO-heavy plugins.

The Wolfi tag, `vX.Y.Z-wolfi`, is native amd64/arm64 only. Use the default tag when you
need s390x or cross-compilation in any direction.

## Editions: CE / EE / EE-FIPS
Build for the **edition of the Gateway you'll run the plugin in** - the `ee` tag gates
enterprise code, and FIPS swaps the crypto module, so a mismatched plugin can fail to load.

| `EDITION` | Gateway image | architectures |
|---|---|---|
| `ce` *(default)* | `tyk-gateway` | amd64 / arm64 / s390x |
| `ee` | `tyk-gateway-ee` | amd64 / arm64 |
| `ee-fips` | `tyk-gateway-fips` | amd64 / arm64 |
```bash
docker run --rm -e EDITION=ee -v "$PWD:/plugin-source" \
  chrisanderton/compile-tyk-plugin:vX.Y.Z my-plugin.so

docker run --rm -e EDITION=ee-fips -v "$PWD:/plugin-source" \
  chrisanderton/compile-tyk-plugin:vX.Y.Z my-plugin.so
```
One image covers all three - the per-edition settings (tags, FIPS mechanism, **and the
published architectures**) are resolved from the edition Gateways and baked per release. Arch
support is **data-driven**: today EE/FIPS are amd64/arm64, but if Tyk adds s390x (or any
arch) to an edition, the watcher detects it and a rebuilt compiler allows + gates it
**with no code change**. Details: **`docs/fips.md`**.

## Verify a plugin
Every build is auto-checked by `validate-plugin.sh`, which **fails with a clear message**
on: wrong GOARCH, Go-version mismatch, GLIBC symbol newer than the target, wrong/missing
edition tag, or musl/missing deps - instead of an opaque `plugin was built with a
different version of package ...` at Gateway start.

Inspect manually:
```bash
file        my-plugin_vX.Y.Z_linux_amd64.so   # ELF class + arch
go version -m my-plugin_vX.Y.Z_linux_amd64.so  # toolchain (must equal the Gateway's) + deps
readelf --version-info my-plugin_vX.Y.Z_linux_amd64.so | grep GLIBC   # max symbol version
```

Confirm it actually loads (the real ABI check) - two reusable scripts, any gateway image:
```bash
# fast: load + symbol via the Gateway's own command (no redis/compose) - used by the gate
./scripts/loadtest-gate.sh \
  chrisanderton/compile-tyk-plugin:vX.Y.Z \
  tykio/tyk-gateway:vX.Y.Z [ce|ee|ee-fips]

# deep: full request path (Gateway + redis + httpbin), asserts the plugin runs
./scripts/e2e-compose.sh \
  chrisanderton/compile-tyk-plugin:vX.Y.Z \
  tykio/tyk-gateway:vX.Y.Z [ce|ee|ee-fips]
```
Or directly: `docker run --rm --entrypoint /opt/tyk-gateway/tyk -v "$PWD/plugin.so:/p.so:ro"
tykio/tyk-gateway:vX.Y.Z plugin load -f /p.so -s MySymbol`.

## Air-gapped builds
The only runtime network dependency is the **Go module proxy** (toolchain, gcc, sysroots
and Gateway source are baked). Point it at a local mirror or a pre-seeded cache:
```bash
# internal proxy (Athens/Artifactory/Nexus):
docker run --rm -e GOPROXY=https://goproxy.internal -e GOSUMDB=off \
  -v "$PWD:/plugin-source" chrisanderton/compile-tyk-plugin:vX.Y.Z my-plugin.so
# fully offline against a pre-populated module cache:
docker run --rm --network none -e GOPROXY=file:///go/pkg/mod/cache/download -e GOSUMDB=off \
  -v tyk-mod-cache:/go/pkg/mod -v "$PWD:/plugin-source" \
  chrisanderton/compile-tyk-plugin:vX.Y.Z my-plugin.so
```
Full guide: **`docs/air-gapped.md`**.

## When to build your own compiler
Do not build this repository for a stock `tykio/tyk-gateway:vX.Y.Z`. Use the matching
prebuilt tag instead.

Build your own compiler only when your Gateway is also custom: a fork, private patch,
custom dependencies, custom build tags, or a different Go toolchain. See
[`docs/custom-gateway.md`](docs/custom-gateway.md).

## macOS / Apple Silicon
Multi-arch, so it runs **natively** on arm64 Macs - no `--platform=linux/amd64` or
emulation (unlike the legacy amd64-only image). Use `-e GOARCH=...` only to cross-compile.

---

## Maintainer docs
The README is intentionally focused on using the prebuilt images. Build and maintenance
details live in the dedicated docs:

- [`docs/maintenance.md`](docs/maintenance.md) - release/build pipeline, watch/prune,
  base/release split.
- [`docs/custom-gateway.md`](docs/custom-gateway.md) - building a compiler for a custom
  Gateway.
- [`docs/base-images.md`](docs/base-images.md) - DHI vs Wolfi base variants.
- [`docs/compatibility.md`](docs/compatibility.md) - ABI and load-test evidence.
- [`docs/glibc-targets.md`](docs/glibc-targets.md) - default glibc floor and rare
  opt-in higher floors.
- [`docs/security-note.md`](docs/security-note.md) - CVE comparison and scanner context.

## Why this exists
Enterprise CVE scanners flag a lot of findings on general-purpose builder images. This
project takes a focused approach for the plugin-compilation job: a hardened, minimal
**Docker Hardened Image** base, with old-glibc CGO compatibility kept as an **isolated
link sysroot** rather than as the OS. The plugin output is equivalent, the image is
modern and small, and scanner findings drop substantially. The official
`tyk-plugin-compiler` is the Gateway's release builder and intentionally carries a
broader toolchain for its wider role; this image only needs what plugin compilation
requires. Compatibility evidence and the CVE comparison: **`docs/compatibility.md`**,
**`docs/security-note.md`**, **`docs/base-images.md`**.

## Known limitations
- **Plugins are version- and edition-locked to the Gateway** (Go `plugin` constraint):
  a plugin only loads into the Gateway build it was compiled for - same Go version,
  dependency graph, build tags. This tool's job is to match that exactly.
- **arm64/s390x plugins need an arm64/s390x Gateway runtime** to load into (you can't
  load a foreign-arch `.so`). EE/EE-FIPS publish amd64/arm64 only; s390x is CE-only.
- **`-race`**: not set by default (production Gateways don't use it); match it yourself
  if you target a `-race` Gateway. Mirrors the official compiler.
- **C++ CGO** (`g++`) is included by default; `--build-arg WITH_CXX=0` drops it.
- **Default user is root**: current tags preserve drop-in compatibility with the
  official compiler, so some scanners may report that no default non-root user is set.
  This is known and acknowledged. If non-root-by-default tags matter for your
  environment, raise or +1 a GitHub issue; the planned path is an opt-in variant, not a
  behavior change to existing tags.

## Repo layout
```
Dockerfile.base          stable layer: DHI + toolchains + glibc sysroots + scripts (no Go/source)
Dockerfile.release       thin per-release layer: FROM base + exact Go + vendored Gateway source
Dockerfile.proof         lean image to validate the sysroot/toolchain without the Gateway
data/build.sh            entrypoint - drop-in interface, sysroot- & edition-aware
data/validate-plugin.sh  post-build validator (arch / Go / GLIBC / edition / deps)
scripts/                 resolve-gateway.sh, loadtest-gate.sh, e2e-compose.sh, validate-proof.sh, cve-compare.sh
loadtest/                test-plugin + docker-compose for E2E
proof/                   tiny CGO plugin for the proof-image toolchain validation
.github/workflows/       build.yml + build-wolfi.yml (DHI + Wolfi pipelines), watch.yml (auto-trigger)
docs/                    base-images.md, compatibility.md, glibc-targets.md, fips.md,
                         air-gapped.md, custom-gateway.md, maintenance.md, security-note.md
```
