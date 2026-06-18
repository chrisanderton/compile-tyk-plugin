# Base images

The compiler is published in three variants. They produce identical plugins; you choose the
one that fits your build needs and supply-chain requirements.

| Variant | Tag | Base | Builds for | Best for |
|---|---|---|---|---|
| Default (native) | `:vX.Y.Z` | DHI busybox-glibc | its own host arch (amd64->amd64, arm64->arm64) | Most users; native amd64/arm64 builds |
| Cross | `:vX.Y.Z-x` | DHI busybox-glibc + cross toolchains | amd64, arm64, s390x (cross) | When you need cross-compilation or s390x |
| Wolfi | `:vX.Y.Z-wolfi` | `cgr.dev/chainguard/wolfi-base` | its own host arch (amd64/arm64) | Lowest CVE count; teams standardized on Chainguard |

All three bases are glibc, which is what matters for compiling CGO Go plugins that load into
the glibc-based Gateway runtime.

## Default: busybox-glibc, native-only

The default `:vX.Y.Z` tag is built on a Docker Hardened Image **busybox-glibc** base: a
hardened, minimal, continuously patched glibc base carrying just the build-time toolchain the
compiler needs (Go, gcc, binutils, the glibc-2.17 link sysroot, scripts). It is **native-only**:
it builds for its own host architecture (amd64->amd64, arm64->arm64) and does not cross-compile.
It is published amd64 + arm64, so Docker pulls the native image for your host.

Native is the preferred path for CGO-heavy plugins. Reach for the `-x` variant only when you
need a different target arch or s390x.

The base inherits DHI's hardening: signed images, SBOMs, SLSA build provenance, and continuous
patching. The base ships an unused-package purge (perl/gpgv/ncurses removed and the distroless
scanner manifest reconciled) so the scan reflects what is actually present.

You pull the published compiler from Docker Hub / GHCR like any image - the DHI base layers are
republished into it, so **no `dhi.io` login is needed to use it**:

```bash
docker pull <you>/compile-tyk-plugin:vX.Y.Z
```

(Only maintainers rebuilding the base need `docker login dhi.io` - with their Docker Hub
credentials, free tier - to pull the upstream DHI base.)

## Cross variant: `-x`

The `-x` tag is the **same busybox-glibc base plus C cross toolchains** for the plugin target
architectures. It cross-compiles to **amd64 / arm64 / s390x** regardless of host, and supports
all three editions:

```bash
docker run --rm -e GOARCH=s390x -v "$PWD:/plugin-source" \
  <you>/compile-tyk-plugin:vX.Y.Z-x my-plugin.so
```

The cross toolchains are the only difference from the default; they add some low-severity
scanner findings (the cross-target binutils BFD-parser advisories) but no new
CRITICALs/HIGHs. See [`security-note.md`](security-note.md) for the measured numbers.

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

## Package trimming on the busybox-glibc base

Both busybox-glibc variants (default and `-x`) have the packages the compiler never uses at
runtime removed, to keep the scan honest and low:

- **Purge unused packages, files and all.** `perl`, `perl-base`, `perl-modules`, `gpgv`,
  `ncurses-base/bin/term`, and the orphaned `libperl` runtime (perl's shared library; its only
  consumer was perl). These are in the live dpkg database, so `apt-get purge` deletes their
  files - not just a manifest entry.
- **No curl.** Go is fetched at build time via BuildKit `ADD` + `sha256sum` verification, so the
  image needs no `curl` CLI (the trust anchor - go.dev plus the pinned checksum - is unchanged).
- **Reconcile the scanner manifest.** The base tracks packages in a distroless
  `/var/lib/dpkg/status.d/` manifest (one file per package) that `apt`/`dpkg` do not update. We
  clear those entries **only for packages we actually removed** - never for one whose files
  remain. Nothing is suppressed or VEX'd; everything still present stays reported.

What stays, and why (load-bearing - removing it would break the build or hide a real package):

- `linux-libc-dev` - native CGO's `<errno.h>` includes `<linux/errno.h>`, so removing it breaks
  native compilation (and the boringcrypto FIPS path). On the `-x` variant, cross builds use the
  2.17 sysroot's own kernel headers. Its findings are kernel-header CVEs (no kernel runs in a
  build image) but we keep the package and leave them honestly reported.
- `libtinfo6` (bash); `libexpat1`/`libcurl`/`libssh2` (git's HTTPS/VCS transport, used to fetch
  plugin modules); `libsqlite3`/`libssl3`/`openssl` (PAM, apt, coreutils, ca-certificates); and
  the Go `stdlib` (tracks the Gateway's Go version).

The full measured CVE picture for every variant is in [`security-note.md`](security-note.md).
The short version: under Trivy `--ignore-unfixed` all variants collapse to the same ~27
findings (the shared Go stdlib), so the *actionable* surface is identical across them.

## The glibc floor is the same across all variants

Whichever base you use, every plugin is linked against a glibc-2.17 sysroot (the RHEL 7 /
CentOS 7 ABI, from `manylinux2014`) baked into the image, independent of the base's own
glibc. This keeps the plugin's required glibc symbols low - loadable on the Gateway runtime
*and* on older native hosts like RHEL 7 - regardless of which base produced it. See
[`compatibility.md`](compatibility.md) for measured ceilings,
[`glibc-targets.md`](glibc-targets.md) for the optional custom-floor mechanism, and
[`../data/sysroot-2.17-digests.txt`](../data/sysroot-2.17-digests.txt) for the pinned
2.17 sources and the arches they cover.

## Using a different base

`Dockerfile.base` is parameterized with `ARG BASE_IMAGE` and detects whether the base
uses `apt` or `apk`, so you can point it at another glibc base:

```bash
docker build -f Dockerfile.base \
  --build-arg BASE_IMAGE=<your-namespace>/dhi-busybox-glibc:dev \
  -t compile-tyk-plugin-base:custom .
```

Notes:

- The base ships no Go. The exact Go version is installed by `Dockerfile.release`, so the
  base is reused unchanged across Gateway releases.
- A **musl** base (for example Alpine) is out of scope: glibc CGO plugins cannot load
  into a musl runtime, and the Gateway runtime is glibc.

## CVE posture

On a raw full Trivy scan, the busybox-glibc **default** carries ~1 CRITICAL / ~49 HIGH / ~1000
total. The lone CRITICAL is `linux-libc-dev` (a Linux kernel CVE attributed to the kernel-UAPI
headers package - no kernel runs in a build image; it is `#include`-only, kept and honestly
reported). The **`-x`** variant adds the cross toolchains: ~the same criticals/highs and ~1100
total, where the extra ~100 are all LOW (cross-target binutils BFD-parser advisories). The
**`-wolfi`** variant is native-only: 0 CRITICAL / 9 HIGH / 27 total, all of it the shared Go
stdlib.

The framing that matters: under Trivy `--ignore-unfixed` (dropping advisories with no fix
available - the won't-fix kernel-header and binutils noise), **all variants collapse to the same
~27 findings - the Go stdlib**. The actionable/fixable surface is identical across variants; the
large raw counts on the busybox-glibc variants are almost entirely unfixed distro noise that is
benign in a build-time image (no kernel, no runtime services). See `docs/security-note.md` for the
full comparison.

Reference: [DHI image types](https://docs.docker.com/dhi/about/available/),
[glibc and musl in DHI](https://docs.docker.com/dhi/core-concepts/glibc-musl/),
[using DHI](https://docs.docker.com/dhi/how-to/use/).
