# Base images

The compiler is published in two variants that differ only in their base operating
system. Both produce identical plugins; you choose the one that fits your supply-chain
requirements.

| Variant | Tag | Base | Architectures | Best for |
|---|---|---|---|---|
| Docker Hardened Image (default) | `:vX.Y.Z` | `dhi.io/debian-base` (dev) | amd64, arm64, s390x | Most users; signed, SBOM-backed supply chain |
| Wolfi | `:vX.Y.Z-wolfi` | `cgr.dev/chainguard/wolfi-base` | amd64, arm64 | Teams standardized on Chainguard |

Both bases are glibc, which is what matters for compiling CGO Go plugins that load into
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

## The glibc floor is the same on both

Whichever base you use, every plugin is linked against a glibc-2.17 sysroot (the RHEL 7 /
CentOS 7 ABI, from `manylinux2014`) baked into the image, independent of the base's own
glibc. This keeps the plugin's required glibc symbols low - loadable on the Gateway runtime
*and* on older native hosts like RHEL 7 - regardless of which base produced it. The floor
is selectable with `--build-arg GLIBC_TARGET=2.17|2.31` (2.17 default; 2.31 is an opt-in
for plugins needing a newer glibc function, and is not RHEL 7 compatible). See
`docs/compatibility.md` for measured ceilings and `data/sysroot-2.17-digests.txt` for the
pinned 2.17 sources and the arches they cover.

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

On a raw Trivy scan (no VEX), the DHI base and a well-trimmed `debian:trixie-slim` land
in a similar place, because both are Debian 13 / glibc. The residual findings are
`perl-base`, which is `Priority: required` on Debian and cannot be removed. DHI's value
over plain trixie is the supply chain around it, not the raw count: signed images, SBOM
and SLSA provenance, VEX attestations (Select/Enterprise), and a support SLA. The Wolfi
variant removes perl entirely for the lowest raw count. See `docs/security-note.md` for
the full comparison.

Reference: [DHI image types](https://docs.docker.com/dhi/about/available/),
[glibc and musl in DHI](https://docs.docker.com/dhi/core-concepts/glibc-musl/),
[using DHI](https://docs.docker.com/dhi/how-to/use/).
