# compile-tyk-plugin

A modern, low-CVE, **multi-arch** compiler for Tyk Go plugins - built to match **any
Tyk Gateway release and edition**, with the **same Docker workflow** as the official
`tyk-plugin-compiler`.

> **Community / unofficial.** Not affiliated with or supported by Tyk. It consumes only
> public Tyk artifacts and publishes to *your own* registry namespace.

Give it a Gateway version; it figures out the rest (exact Go toolchain, commit, FIPS/EE
settings) from the published Gateway image and produces a matching compiler.

What it gives you:
- **Docker Hardened Image base** - hardened, minimal, continuously patched. In our
  measurements this means far fewer CVE-scanner findings (about 85-90% fewer
  CRITICAL/HIGH).
- **Native multi-arch builds** - amd64 and arm64 images each run on their own
  architecture, with no emulation (including on Apple Silicon), so builds are faster.
- **One image, many targets** - cross-compiles amd64/arm64/s390x and builds for the
  **CE / EE / EE-FIPS** editions, all selected with a flag.
- **Old-glibc CGO compatibility as an isolated link sysroot** - plugins link against a
  pinned glibc-2.17 floor (RHEL 7 / CentOS 7 ABI; `GLIBC_TARGET=2.31` to opt up) for
  broad portability, while the image itself stays modern and small.

It is purpose-built for compiling plugins. The official `tyk-plugin-compiler` is a
general-purpose Gateway release builder that does more than compile plugins, so a direct
package-count or CVE comparison is not apples-to-apples; the figures above reflect a base
chosen specifically for the plugin-compilation job.

`vX.Y.Z` below is any published Gateway version (examples use `v5.13.0`). Replace
`compile-tyk-plugin` with your published image, e.g. `youruser/compile-tyk-plugin` or
`ghcr.io/youruser/compile-tyk-plugin`.

---

## Quick start - build a plugin
```bash
docker run --rm -v "$PWD:/plugin-source" compile-tyk-plugin:vX.Y.Z my-plugin.so
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
  builds (below); `TYK_GLIBC_TARGET`/`TYK_PLUGIN_SYSROOT_BASE` to retarget the sysroot.

Output naming matches the official convention: `{name}_{Gw-version}_{GOOS}_{GOARCH}.so`.

## Architectures & cross-compilation
One image carries glibc sysroots + cross toolchains for **amd64, arm64, s390x**, so any
target builds via `GOARCH` regardless of host:
```bash
docker run --rm -e GOARCH=arm64 -v "$PWD:/plugin-source" compile-tyk-plugin:vX.Y.Z my-plugin.so
docker run --rm -e GOARCH=s390x -v "$PWD:/plugin-source" compile-tyk-plugin:vX.Y.Z my-plugin.so  # big-endian, CE only
```
The compiler image itself is published amd64 + arm64 (native on each); s390x is a
cross target. Prefer the native image of the target arch for CGO-heavy plugins.

## Editions: CE / EE / EE-FIPS
Build for the **edition of the Gateway you'll run the plugin in** - the `ee` tag gates
enterprise code, and FIPS swaps the crypto module, so a mismatched plugin can fail to load.

| `EDITION` | Gateway image | architectures |
|---|---|---|
| `ce` *(default)* | `tyk-gateway` | amd64 / arm64 / s390x |
| `ee` | `tyk-gateway-ee` | amd64 / arm64 |
| `ee-fips` | `tyk-gateway-fips` | amd64 / arm64 |
```bash
docker run --rm -e EDITION=ee      -v "$PWD:/plugin-source" compile-tyk-plugin:vX.Y.Z my-plugin.so
docker run --rm -e EDITION=ee-fips -v "$PWD:/plugin-source" compile-tyk-plugin:vX.Y.Z my-plugin.so
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
./scripts/loadtest-gate.sh compile-tyk-plugin:vX.Y.Z tykio/tyk-gateway:vX.Y.Z [ce|ee|ee-fips]

# deep: full request path (Gateway + redis + httpbin), asserts the plugin runs
./scripts/e2e-compose.sh   compile-tyk-plugin:vX.Y.Z tykio/tyk-gateway:vX.Y.Z [ce|ee|ee-fips]
```
Or directly: `docker run --rm --entrypoint /opt/tyk-gateway/tyk -v "$PWD/plugin.so:/p.so:ro"
tykio/tyk-gateway:vX.Y.Z plugin load -f /p.so -s MySymbol`.

## Air-gapped builds
The only runtime network dependency is the **Go module proxy** (toolchain, gcc, sysroots
and Gateway source are baked). Point it at a local mirror or a pre-seeded cache:
```bash
# internal proxy (Athens/Artifactory/Nexus):
docker run --rm -e GOPROXY=https://goproxy.internal -e GOSUMDB=off \
  -v "$PWD:/plugin-source" compile-tyk-plugin:vX.Y.Z my-plugin.so
# fully offline against a pre-populated module cache:
docker run --rm --network none -e GOPROXY=file:///go/pkg/mod/cache/download -e GOSUMDB=off \
  -v tyk-mod-cache:/go/pkg/mod -v "$PWD:/plugin-source" compile-tyk-plugin:vX.Y.Z my-plugin.so
```
Full guide: **`docs/air-gapped.md`**.

## Custom / self-built Gateway
Plugins are ABI-bound to a *specific* Gateway build. If you run your own Gateway (fork,
custom deps/tags, different Go), build a compiler from **your** source - the Dockerfiles
and the build workflow are source-agnostic (`source_repo`/`source_ref`/`*_repo` inputs,
or `GATEWAY_REPO=` for the resolver). Guide: **`docs/custom-gateway.md`**.

## macOS / Apple Silicon
Multi-arch, so it runs **natively** on arm64 Macs - no `--platform=linux/amd64` or
emulation (unlike the legacy amd64-only image). Use `-e GOARCH=...` only to cross-compile.

---

## How images are built & published (maintainers)
Self-contained pipeline - input is just a Gateway version; everything else is derived
from public artifacts. Publish to your own Docker Hub + GHCR namespaces.

```
resolve (Gateway version -> Go ver, commit, EE/FIPS settings, Go checksums)
  -> base    (Dockerfile.base: DHI + toolchains + glibc sysroots + scripts; slow cadence)
  -> gate    (build candidate, load-test EVERY available edition into its matching
              Gateway on amd64 AND arm64 - publish blocks unless all pass)
  -> publish (Dockerfile.release: FROM base + exact Go + vendored Gateway source;
              multi-arch -> GHCR + Docker Hub, SBOM + provenance)
```
- `.github/workflows/build.yml` - run it with a `gateway_version` (custom `*_repo` /
  `source_*` inputs optional). Config: `DOCKERHUB_USER` (repo **variable** = username +
  namespace) and `DOCKERHUB_TOKEN` (repo **secret** = Read & Write PAT, also pulls the
  `dhi.io` base); GHCR uses the built-in `GITHUB_TOKEN`.
- `.github/workflows/watch.yml` - daily; auto-builds **new proper releases** (no rc/alpha)
  and re-stacks when the DHI base or an EE/FIPS gateway changes.
- Local checks without the heavy build: `docker build -f Dockerfile.proof -t ctp:proof .`
  then `./scripts/validate-proof.sh`; CVE comparison via `./scripts/cve-compare.sh`.

Design and maintenance (why per-release is inherent to native Go plugins; the
base/release split; what auto-adapts vs. needs a maintainer): **`docs/maintenance.md`**.

### Tags
| Tag | Meaning |
|---|---|
| `:vX.Y.Z` | default (DHI base), multi-arch (amd64+arm64); moving - always the latest patched build |
| `:vX.Y.Z-YYYYMMDD` | immutable, for pinning |
| `:vX.Y.Z-wolfi` | Wolfi/Chainguard base variant (amd64+arm64 native only; see below) |
| `-base:latest` | the stable toolchain/sysroot base layer |

### Wolfi variant (for Chainguard shops)
A second base is published from `build-wolfi.yml` as `:vX.Y.Z-wolfi` for teams
standardised on Chainguard. Wolfi is glibc-based with no perl in the base, so it scans
extremely cleanly; it ships no cross-compilers, so this variant builds **natively for
amd64 and arm64 only** (no s390x, no cross). All editions (CE/EE/EE-FIPS) are supported
for those two architectures. The default DHI image remains the full-coverage build
(all target architectures, cross in any direction). See **`docs/base-images.md`**.

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
- **The production image build is heavy** (vendors the Gateway + a large module
  download). ABI correctness is proven by the CI gate, which loads a freshly built
  plugin into the real Gateway before publishing (`docs/compatibility.md`).

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
docs/                    base-images.md, compatibility.md, fips.md, air-gapped.md,
                         custom-gateway.md, maintenance.md, security-note.md
```
