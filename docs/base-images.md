# Base images

The compiler is published in three variants. They produce identical plugins; you choose the
one that fits your supply-chain requirements.

| Variant | Tag | Base | Architectures | Best for |
|---|---|---|---|---|
| Docker Hardened Image (default) | `:vX.Y.Z` | `dhi.io/debian-base` (dev) | amd64, arm64, s390x | Most users; signed, SBOM-backed supply chain |
| Slim (trimmed DHI) | `:vX.Y.Z-slim` | same DHI base, unused packages purged | amd64, arm64, s390x | Lowest-CVE option that still cross-compiles |
| Wolfi | `:vX.Y.Z-wolfi` | `cgr.dev/chainguard/wolfi-base` | amd64, arm64 | Teams standardized on Chainguard |

All three bases are glibc, which is what matters for compiling CGO Go plugins that load into
the glibc-based Gateway runtime.

## Default: Docker Hardened Image

The Gateway itself runs on a Docker Hardened Image (DHI) runtime base. The compiler uses
the **dev variant** of the same DHI family (`debian-base`): same hardened, continuously
patched Debian lineage, but with the shell, package manager, and build tools the compiler
needs. The runtime variant strips those out and cannot compile.

Using the same hardened base across build and runtime gives you one libc story and
consistent attestations: the compiler inherits DHI's signed images, SBOMs, SLSA build
provenance, and continuous patching, with VEX and FIPS/STIG variants available on the
Select and Enterprise tiers.

The DHI base requires authentication (free tier):

```bash
docker login dhi.io          # use your Docker Hub credentials
docker pull <you>/compile-tyk-plugin:vX.Y.Z
```

## Wolfi variant

For teams standardized on Chainguard, the `-wolfi` tag is built on
`cgr.dev/chainguard/wolfi-base`. Wolfi carries no perl in its base, so its CVE scan is
very clean. The trade-offs:

- **Native builds only.** Wolfi does not package cross-compilers, so the Wolfi image
  builds for its own architecture (amd64 or arm64). It cannot cross-compile and does not
  support s390x. The image rejects unsupported targets with a clear message.
- **Rolling base.** Wolfi is continuously rebuilt; the workflow pins it by digest.

All three editions (CE, EE, EE-FIPS) are supported on the Wolfi variant for amd64 and
arm64.

## Slim variant (trimmed DHI)

The `-slim` tag is the **same DHI base and the same cross toolchains as the default**
`:vX.Y.Z` - it still cross-compiles amd64/arm64/s390x and supports all three editions. It
only has the packages the compiler never uses at runtime removed, to lower the CVE scan.

How it is built (`SLIM=1` in `Dockerfile.base`):

- **Purge unused packages, files and all.** `perl`, `perl-base`, `perl-modules`, `gpgv`,
  `ncurses-base/bin/term`, and the orphaned `libperl` runtime (perl's shared library; its only
  consumer was perl). These are in the live dpkg database, so `apt-get purge` deletes their
  files - not just a manifest entry.
- **No curl.** Go is fetched at build time via BuildKit `ADD` + `sha256sum` verification, so the
  image needs no `curl` CLI (the trust anchor - go.dev plus the pinned checksum - is unchanged).
- **Reconcile the scanner manifest.** DHI tracks packages in a distroless
  `/var/lib/dpkg/status.d/` manifest (one file per package) that `apt`/`dpkg` do not update. We
  clear those entries **only for packages we actually removed** - never for one whose files
  remain. Nothing is suppressed or VEX'd; everything still present stays reported.

What stays, and why (load-bearing - removing it would break the build or hide a real package):

- `linux-libc-dev` - native CGO's `<errno.h>` includes `<linux/errno.h>`, so removing it breaks
  native compilation (and the boringcrypto FIPS path). Cross builds use the 2.17 sysroot's own
  kernel headers. Its findings are kernel-header CVEs (no kernel runs in a build image) but we
  keep the package and leave them honestly reported.
- `libtinfo6` (bash); `libexpat1`/`libcurl`/`libssh2` (git's HTTPS/VCS transport, used to fetch
  plugin modules); `libsqlite3`/`libssl3`/`openssl` (PAM, apt, coreutils, ca-certificates); and
  the Go `stdlib` (tracks the Gateway's Go version).

Measured, arm64, raw Trivy (no VEX): the default DHI image scans **9 CRITICAL / 77 HIGH**; the
`-slim` image scans **1 CRITICAL / 58 HIGH**. The one remaining critical is `linux-libc-dev`.

### Why not a more minimal base (e.g. busybox)?

A reasonable suggestion is to rebuild the compiler on a busybox/distroless base, the way the
Gateway image is. We measured it and chose the slim-purge of the DHI base instead:

- **The compiler is a build environment, not a runtime image.** The Gateway's minimal image
  (`ci/Dockerfile.distroless` in `TykTechnologies/tyk`) builds the gateway `.deb` on Debian, then
  `COPY`s the single finished `tyk` binary onto a minimal base - nothing is installed on that
  base. That works because the gateway is one self-contained binary. The compiler's payload is the
  whole toolchain (Go + gcc + three cross-gccs + sysroots), which has to be present and runnable
  in the image because you run the compile *inside* it. A busybox base has no package manager and
  no compiler, so adopting it would mean hand-`COPY`ing the entire gcc + cross-gcc shared-library
  closure into it - a large, fragile maintenance surface.
- **It would not beat the existing Wolfi variant.** The DHI scan count is dominated by `binutils`
  (540 findings across its 10 sub-packages) and `linux-libc-dev` kernel headers (353) plus glibc -
  all intrinsic to a *cross*-compiler, so they ride along on any base. A busybox image carrying the
  same Debian cross toolchain would still report ~900. Wolfi reaches a near-zero OS count only
  because it is
  **native-only** (no cross binutils) and Chainguard-patched - which is exactly what `-wolfi`
  already offers for teams that don't need cross/s390x.
- **The criticals were never in the toolchain.** On the DHI baseline, all 9 criticals and most
  highs were in droppable packages (perl alone was 8 of the 9 criticals; the rest curl, sqlite,
  expat, ncurses). A purge clears those with no base swap and no toolchain risk.
- **The real blocker to a lower scan was the scanner manifest, not the base.** DHI bakes the
  distroless `status.d` manifest (and an SBOM under `/opt/docker/sbom`) that `apt`/`dpkg` do not
  update, so scanners keep reporting packages you have already removed. Reconciling the manifest -
  not changing the base - is what makes the reduction real.

## The glibc floor is the same across all variants

Whichever base you use, every plugin is linked against a glibc-2.17 sysroot (the RHEL 7 /
CentOS 7 ABI, from `manylinux2014`) baked into the image, independent of the base's own
glibc. This keeps the plugin's required glibc symbols low - loadable on the Gateway runtime
*and* on older native hosts like RHEL 7 - regardless of which base produced it. See
[`compatibility.md`](compatibility.md) for measured ceilings,
[`glibc-targets.md`](glibc-targets.md) for the rare higher-floor opt-in, and
[`../data/sysroot-2.17-digests.txt`](../data/sysroot-2.17-digests.txt) for the pinned
2.17 sources and the arches they cover.

## Using a different base

`Dockerfile.base` is parameterized with `ARG BASE_IMAGE` and detects whether the base
uses `apt` or `apk`, so you can point it at another glibc base:

```bash
docker build -f Dockerfile.base \
  --build-arg BASE_IMAGE=<your-namespace>/dhi-debian-base:13-dev \
  -t compile-tyk-plugin-base:custom .
```

Notes:

- The base ships no Go. The exact Go version is installed by `Dockerfile.release`, so the
  base is reused unchanged across Gateway releases.
- A **musl** base (for example Alpine) is out of scope: glibc CGO plugins cannot load
  into a musl runtime, and the Gateway runtime is glibc.

## CVE posture

On a raw Trivy scan (no VEX), the **default** DHI image and a well-trimmed
`debian:trixie-slim` land in a similar place, because both are Debian 13 / glibc. DHI's
value over plain trixie is the supply chain around it, not the raw count: signed images,
SBOM and SLSA provenance, VEX attestations (Select/Enterprise), and a support SLA.

The **`-slim`** variant trims the unused packages from that same DHI base - including the
perl family, which is removable with `apt-get purge --allow-remove-essential` despite being
`Priority: required` - for a much lower raw count while keeping cross-compilation (measured:
9 CRITICAL / 77 HIGH -> 1 CRITICAL / 58 HIGH on arm64). The **`-wolfi`** variant is
native-only with a near-zero count. See the "Slim variant" section above and
`docs/security-note.md` for the full comparison.

Reference: [DHI image types](https://docs.docker.com/dhi/about/available/),
[glibc and musl in DHI](https://docs.docker.com/dhi/core-concepts/glibc-musl/),
[using DHI](https://docs.docker.com/dhi/how-to/use/).
