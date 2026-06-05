# Maintenance and design

This page explains how the compiler is kept current across Gateway releases, and which
changes are absorbed automatically versus which need a maintainer. It is aimed at anyone
running or contributing to this repository.

## Why a compiler exists per Gateway release

A Go `-buildmode=plugin` object is rejected at load unless it was built with the exact
Go toolchain and the exact module versions of the Gateway it loads into. A plugin for
Gateway `vX.Y.Z` must therefore be compiled against that release's Go version and module
graph. One universal compiler image is not possible.

The goal of this design is to make producing each release's compiler cheap and
automatic, and to decouple security patching from the Gateway's release cadence.

## Two-layer image

The Dockerfile is split so the slow-moving, expensive parts are built rarely and the
release-specific parts are cheap to rebuild:

```
compile-tyk-plugin-base:<toolchain-date>     # slow cadence
  base OS + gcc and cross toolchains + glibc-2.31 sysroots + build.sh + validator

compile-tyk-plugin:vX.Y.Z                    # per release, cheap
  FROM compile-tyk-plugin-base
    + exact Go (derived from the Gateway) + vendored Gateway source + go mod download
```

This split is the central structural choice. It means:

- **Per-release builds are fast.** They reuse the toolchain and sysroots instead of
  rebuilding them, so a release layer builds in seconds on a warm base.
- **Security patching is decoupled from releases.** When the base OS gets a CVE patch,
  rebuild only the base and re-stack the maintained release layers on it, published as
  `vX.Y.Z-2`, `vX.Y.Z-3`, and so on. The Go version and dependencies are unchanged, so
  plugins still load; only the OS is fresher. A single combined image cannot do this.

## Everything release-specific is a build arg

No Dockerfile edits are needed per release. The release layer takes:
`GO_VERSION`, `GITHUB_SHA`, `GITHUB_TAG`, `BUILD_TAG`, `GOFIPS140`, `BASE_IMAGE`,
`GLIBC_TARGET`, `WITH_CXX`, `WITH_GIT`, `WITH_GATEWAY_SELFTEST`.

The Go version is not hardcoded. `scripts/resolve-gateway.sh` reads it directly from the
published Gateway binary (`go version -m`) and fetches the matching checksums from
go.dev, so the compiler always follows whatever Go the Gateway was built with. The two
can never drift.

## What auto-adapts versus what needs a maintainer

Most release-to-release change is derived from the published Gateway, so a rebuild
absorbs it with no code change.

**Auto-adapts** (`watch.yml` rebuilds, `resolve-gateway.sh` derives it):

- **Go version** - read from the Gateway binary; checksums fetched from go.dev. Verified
  across releases from go1.16 through go1.25.
- **Edition settings** - the `ee` build tag and the FIPS mechanism (native `GOFIPS140`
  versus legacy `boringcrypto`), derived from the EE and FIPS Gateway binaries.
- **Per-edition architectures** - read from each Gateway manifest; the build's arch guard
  and the CI gate matrix follow them. A new architecture within an existing toolchain is
  picked up automatically.
- **Newer runtime glibc** - plugins target a fixed glibc-2.31 floor, so any forward move
  in the runtime's glibc still loads.
- **Base CVEs** - the hardened base is patched upstream; `watch.yml` rebuilds when the
  base digest changes.

**Needs a maintainer** (small, localized, and the build tells you when):

- **A brand-new target architecture** (for example ppc64le or riscv64): add its cross
  packages and sysroot to `Dockerfile.base` and a `CC` / dynamic-linker case to
  `build.sh` (about three edits). Until then, `build.sh` fails with an actionable message
  listing the supported set rather than misbuilding silently.
- **A Gateway moving to a musl runtime**: glibc CGO plugins cannot load into musl, so this
  needs a musl toolchain and sysroot variant. The CI gate catches it by failing the load
  test against the new Gateway.
- **A Gateway built with a non-stock Go** (not published on go.dev): supply its checksum.

The CI gate is the universal backstop. Whatever changes, a release publishes only after a
freshly built plugin actually loads into the real new Gateway for every edition and
architecture, so an unforeseen incompatibility blocks the release instead of shipping
broken.

## Rebuild cadence

| Trigger | What rebuilds | Tag |
|---|---|---|
| New Gateway release | release layer (Go version + source auto-derived) | `vX.Y.Z` |
| Base CVE update, no Gateway change | base layer only, re-stack releases | `vX.Y.Z-N` |
| Toolchain / sysroot / glibc-target change | base layer | new base date + re-stack |
| Go bump within a release line | follows the Gateway automatically | unchanged |

## How the repository implements it

The compiler consumes only public artifacts and publishes to both Docker Hub and GHCR
under your namespace. The external contract is a single input: the Gateway version.

| File | Role |
|---|---|
| `scripts/resolve-gateway.sh` | Input `vX.Y.Z`. Reads the published Gateway image and emits `GITHUB_SHA`, the exact `GO_VERSION`, Go checksums, and per-edition settings. |
| `Dockerfile.base` | Stable layer: base OS, toolchains, glibc-2.31 sysroots, scripts. No Go or source. Records the base digest it was built from (label `io.ctp.dhi-base-digest`). |
| `Dockerfile.release` | `FROM` base, plus the exact Go and the vendored Gateway source. Built per release. |
| `.github/workflows/build.yml` | `resolve -> base -> gate -> publish`. The gate is a matrix over amd64 and arm64 (native runners, no QEMU): each builds a candidate compiler, builds the test plugin with it, loads it into the matching Gateway, and asserts the plugin runs. Publish is blocked unless every gate passes. |
| `scripts/loadtest-gate.sh` | The gate logic: build a plugin, then verify it loads via the Gateway's own `tyk plugin load -s <symbol>` ABI check. Reusable standalone. |
| `.github/workflows/build-wolfi.yml` | Wolfi variant: same resolver, native amd64/arm64 only, publishes `:vX.Y.Z-wolfi`. |
| `.github/workflows/watch.yml` | Daily cron with two triggers: a new Gateway version builds it; a new base digest re-stacks all maintained versions on the fresh base. Candidate versions are proper-semver git tags that also have a published gateway image (git tags intersect registry tags), not GitHub Releases, which are inconsistent. From the candidates it keeps the tip of each line whose latest image was published within `activity_days` (default 120), plus the latest release - so it tracks "latest + active LTS" with no hand-maintained list, because a non-LTS line stops getting tags at EOL while an LTS keeps them for ~24 months. Seed the first run with `activity_days=30` (latest + active LTS only). Manual `build.yml` dispatch allows any version, including release candidates. |

## CI credentials

The workflows need one secret pair: `DOCKERHUB_USER` and `DOCKERHUB_TOKEN`. The token is
a Docker Hub Personal Access Token with **Read & Write** scope - Write to push images,
Read to pull the `dhi.io` base. GHCR uses the built-in `GITHUB_TOKEN`.

To create the token: Docker Hub - Account settings - Personal access tokens - Generate
new token. A single token works for both `docker login docker.io` and
`docker login dhi.io`. Store it as the `DOCKERHUB_TOKEN` repository secret and your
username as `DOCKERHUB_USER`.

## Renaming the image

The image name is the `IMAGE_NAME` environment variable in `build.yml` and `watch.yml`.
Change it in one place to publish under a different name.
