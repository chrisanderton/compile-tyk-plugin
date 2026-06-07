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
  base OS + gcc and cross toolchains + glibc sysroots (2.17 default) + build.sh + validator

compile-tyk-plugin:vX.Y.Z                    # per release, cheap
  FROM compile-tyk-plugin-base
    + exact Go (derived from the Gateway) + vendored Gateway source + go mod download
```

This split is the central structural choice. It means:

- **Per-release builds are fast.** They reuse the toolchain and sysroots instead of
  rebuilding them, so a release layer builds in seconds on a warm base.
- **Security patching is decoupled from releases.** When the base OS gets a CVE patch,
  rebuild only the base and re-stack the maintained release layers on it. The moving tag
  `:vX.Y.Z` is refreshed to the latest-patched build and an immutable snapshot
  `:vX.Y.Z-YYYYMMDD` is published. The Go version and dependencies are unchanged, so
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
- **Dependency-alignment method** - `build.sh` picks it by Gateway era: **workspace** (`go work`,
  Go >= 1.18, default), **replace** (module-mode pre-1.18), or **gopath** (old GOPATH-built
  Gateways such as v5.0.x, where deps are baked at `/go/src/...` and a module-mode build would be
  rejected). `resolve-gateway.sh` detects the GOPATH layout and emits `GATEWAY_SRC_ROOT`; the
  plugin then builds against the same paths so `plugin.Open` accepts it. Proven loading v5.0.13.
- **Edition settings** - the `ee` build tag and the FIPS mechanism (native `GOFIPS140`
  versus legacy `boringcrypto`), derived from the EE and FIPS Gateway binaries.
- **Per-edition architectures** - read from each Gateway manifest; the build's arch guard
  and the CI gate matrix follow them. A new architecture within an existing toolchain is
  picked up automatically.
- **Newer runtime glibc** - plugins target a fixed glibc-2.17 floor (RHEL 7 ABI), so any forward move
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

## Which versions are maintained

The supported set is **declared** in [`releases.yml`](../releases.yml), not inferred - so it is
auditable and a deprecation is a reviewed PR. Three classes:

- **`maintained`** - whole minor lines (latest, LTS, LTS-1). Every patch of the line gets a builder;
  the newest `patch_depth` (default 3) stay base-CVE-current (**ACTIVE**), the rest **freeze** (kept,
  not updated).
- **`maintained_extra`** - exact one-off versions (`vX.Y.Z`) to keep ACTIVE even though their line is
  not in `maintained`.
- **`retired`** - out of support, kept available only for in-line upgrades: a line `5.2` keeps its
  final patch; a version `v5.1.4` keeps itself. Frozen, latest snapshot only.

Precedence on overlap is **specific beats wildcard, ACTIVE beats FROZEN beats deleted** - e.g.
`retired: ["5.8"]` + `maintained_extra: ["v5.8.4"]` retires the whole 5.8 line to its tip *except*
v5.8.4, which stays actively maintained. Anything in no class is pruned. Full lifecycle and the
customer-facing tag/retention contract are in [`SUPPORT.md`](../SUPPORT.md).

## Rebuild cadence

| Trigger | What rebuilds | Tag |
|---|---|---|
| New Gateway release | release layer (Go version + source auto-derived) | moving `:vX.Y.Z` + `:vX.Y.Z-YYYYMMDD` |
| Base CVE update, no Gateway change | base layer only, re-stack the ACTIVE set (DHI/Wolfi independent) | `:vX.Y.Z` refreshed + new `:vX.Y.Z-YYYYMMDD` |
| Toolchain / sysroot / glibc-target change | base layer | new base + re-stack ACTIVE |
| Go bump within a release line | follows the Gateway automatically | unchanged |

The moving `:vX.Y.Z` (and `:vX.Y.Z-wolfi`) always points at the latest-patched build - track it
for currency. The dated `:vX.Y.Z-YYYYMMDD` snapshots are immutable pins, retained for
`snapshot_retention_days` (default 14) on actively-updated versions. See `SUPPORT.md`.

## How the repository implements it

The compiler consumes only public artifacts and publishes to both Docker Hub and GHCR
under your namespace. The external contract is a single input: the Gateway version.

| File | Role |
|---|---|
| `scripts/resolve-gateway.sh` | Input `vX.Y.Z`. Reads the published Gateway image and emits `GITHUB_SHA`, the exact `GO_VERSION`, Go checksums, and per-edition settings. |
| `Dockerfile.base` | Stable layer: base OS, toolchains, glibc sysroots (2.17 default), scripts. No Go or source. Records the base digest it was built from (label `io.ctp.dhi-base-digest`). |
| `Dockerfile.release` | `FROM` base, plus the exact Go and the vendored Gateway source. Built per release. |
| `.github/workflows/build.yml` | `resolve -> base -> build-candidate -> gate -> publish`. The compiler image is edition-agnostic, so it is built ONCE per arch (native amd64/arm64 runners, no QEMU) and pushed to GHCR by digest. The gate then pulls that image and loads a real plugin into the matching Gateway for every edition/arch. Publish stitches the two gated per-arch images into one multi-arch manifest (`imagetools create`, no rebuild) and tags it in GHCR + Docker Hub, so you publish the exact images the gate proved. Publish is blocked unless every gate passes. |
| `scripts/loadtest-gate.sh` | The gate logic: build a plugin, then verify it loads via the Gateway's own `tyk plugin load -s <symbol>` ABI check. Reusable standalone. |
| `.github/workflows/build-wolfi.yml` | Wolfi variant: same resolver, native amd64/arm64 only, publishes `:vX.Y.Z-wolfi`. |
| `releases.yml` | **The support policy - single source of truth.** Declares `maintained` (whole minor lines), `maintained_extra` (exact one-off versions), `retired` (lines -> keep tip / versions -> keep that one), plus `patch_depth` and `snapshot_retention_days`. Editing it via PR is how you change what is built and kept. See `SUPPORT.md`. |
| `scripts/resolve-releases.sh` | Resolves `releases.yml` against buildable Gateway versions (git tag AND published image) into `ACTIVE` (base-CVE-updated) + `FROZEN` (built once, kept) sets. Shared by `watch.yml` and `prune.yml` so they cannot drift. |
| `.github/workflows/watch.yml` | Daily cron. Reads the resolver and: **builds** any kept version (ACTIVE or FROZEN) missing an image - new releases plus the one-time backfill of a maintained line's older patches (throttled by `max_dispatch`, default 12/run); **rebuilds** on edition/arch drift (ACTIVE only); **re-stacks** any ACTIVE version **not on the live base** - level-triggered per version (it compares each image's recorded `io.ctp.dhi-base-digest` to the live base), so a run capped by `max_dispatch` or a failed build simply catches up next run rather than leaving versions silently stale. DHI and Wolfi bases are checked **independently**. Buildable versions are proper-semver git tags that also have a published gateway image (not GitHub Releases, which are inconsistent). Manual `build.yml` dispatch still allows any version, including release candidates. |
| `.github/workflows/prune.yml` | Weekly cron; **enforces** `releases.yml` on the registry. Keeps exactly ACTIVE + FROZEN: moving `:vX.Y.Z[-wolfi]` always; ACTIVE dated snapshots within `snapshot_retention_days`; FROZEN keep only their latest snapshot; deletes out-of-policy versions. Applies by default - run once with `dry_run=true` to preview. Safe to automate because it applies a reviewed file, not an inference. |

## CI credentials

The workflows need two pieces of configuration under Settings -> Secrets and variables
-> Actions:

- `DOCKERHUB_USER` - a repository **variable** (not a secret): your Docker Hub username,
  which is also the push namespace (`docker.io/<DOCKERHUB_USER>/...`). It must be a
  variable, not a secret, because GitHub masks secrets and refuses to expose them as step
  outputs - a namespace stored as a secret collapses the push tag to `docker.io//...`.
- `DOCKERHUB_TOKEN` - a repository **secret**: a Docker Hub Personal Access Token with
  **Read & Write** scope. Write pushes images; Read pulls the `dhi.io` base. One token
  works for both `docker login docker.io` and `docker login dhi.io`.

GHCR uses the built-in `GITHUB_TOKEN`. Each workflow's first job runs a preflight that
fails fast if either value is unset (GitHub has no way to declare a variable `required`).

- `GHCR_PRUNE_TOKEN` - an **optional** repository secret, needed only by `prune.yml`: a
  **classic** PAT with the `delete:packages` scope (Settings -> Developer settings -> Personal
  access tokens -> **Tokens (classic)**). Fine-grained PATs do not expose package scopes and
  cannot delete GHCR container versions. The built-in `GITHUB_TOKEN` usually cannot delete
  *user-owned* GHCR package versions either, so without this the GHCR side of a prune logs a
  failure (Docker Hub uses `DOCKERHUB_TOKEN`). Not needed if you do not run the pruner.

To create the token: Docker Hub - Account settings - Personal access tokens - Generate
new token.

## Renaming the image

The image name is the `IMAGE_NAME` environment variable in `build.yml` and `watch.yml`.
Change it in one place to publish under a different name.
