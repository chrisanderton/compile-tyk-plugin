# Security note - a hardened, minimal base for plugin compilation

This note explains why a purpose-built plugin-compiler image produces far fewer
CVE-scanner findings than a general-purpose Gateway release builder, and why that
reduction is structural rather than cosmetic.

## Headline (measured, Trivy 0.71, full severity range)

| Metric | Release builder | This image (trixie, +git) | This image (trixie, no git) | This image (Wolfi)* |
|---|---:|---:|---:|---:|
| CRITICAL | 16 | 8 | **2** | **0** |
| HIGH | 380 | 51 | **36** | low |
| **CRIT+HIGH** | **396** | 59 (-85%) | **38 (-90%)** | - |
| Total findings | 3699 | 1024 (-72%) | fewer | fewest |
| Installed OS packages | 364 | 185 | ~175 | ~minimal |

"Release builder" = the official `tyk-plugin-compiler@sha256:ce908f76...` (a
goreleaser-cross image that also builds and packages the Gateway). "This image" =
`debian:trixie-slim` + a glibc-2.31 link sysroot (the DHI base gives comparable
numbers - see `docs/base-images.md`). \*Wolfi = `cgr.dev/chainguard/wolfi-base` (measured:
no perl in the base even after installing gcc 16.1 + glibc-dev - see below). A
package-count comparison is not strictly apples-to-apples, since the release builder
does more than compile plugins; the point is that a focused base carries less.

### What the CRITICALs actually are (and how they go to 0)
The new image's CRITICALs were **100% perl** - two CVEs with **no upstream fix**
(`CVE-2026-42496`, `CVE-2026-8376`) counted across the perl packages:

- **6 of 8** come from *full* perl, which Debian's **`git`** pulls in transitively
  (`git -> liberror-perl -> perl`). build.sh used perl for a single line (parsing
  `v5.13.0` from the tag); that is now done in **bash** (`BASH_REMATCH`), and `git`
  is **opt-out** (`WITH_GIT=0`) since the default proxy-based `go get` needs no git.
  Dropping git -> **CRITICAL 8 -> 2, HIGH 51 -> 36** (measured).
- **2 of 8** are `perl-base`, which is `Priority: required` on Debian and cannot be
  removed without breaking dpkg/debconf. These are unavoidable on *any* Debian base.
- **Switching `BASE_IMAGE` to Wolfi removes perl entirely -> 0 perl CVEs** (verified:
  `cgr.dev/chainguard/wolfi-base` has no perl, and `apk add gcc glibc-dev binutils`
  installs a glibc toolchain without pulling perl).

## Why the findings drop (and why it is structural)

1. **Current, supported base.** This image uses Debian 13 *trixie* (glibc 2.41), the
   same lineage as the Gateway runtime. Many MEDIUM/LOW findings on an older base are
   "fixed in a newer version" advisories that a current base does not carry. The
   release builder is on Debian 11 *bullseye*, which is older.

2. **Only the toolchain plugin builds use.** This image installs gcc/binutils for the
   plugin's C/CGO needs. It does not include clang/LLVM. The release builder carries
   clang/LLVM for its own purposes, but plugin compilation does not use them.

3. **Cross toolchains scoped to plugin targets.** This image carries C cross
   toolchains for the architectures plugins target (amd64/arm64/s390x). The release
   builder also builds the Gateway itself for additional targets (for example
   powerpc64le), so it reasonably carries more.

4. **No release/packaging tooling.** Release automation and packaging dependencies
   (the goreleaser and dpkg-cross Perl/HTTP libraries) are part of the Gateway's
   release job, not of compiling a plugin, so they are absent here.

5. **Small, auditable surface.** Package managers and caches are cleaned; the image
   keeps only what `build.sh` uses (bash, jq, gcc, binutils, file, make, Go; git is
   optional via `WITH_GIT`).

## Old glibc as a sysroot, not the OS - the central architectural point

CGO plugins need **glibc symbol compatibility** with the Gateway runtime. This image
provides that without running an old OS:

- The old glibc (2.31) exists **only as files under `/opt/tyk/sysroots/`** - `libc`,
  the dynamic loader, `crt*.o`, headers, and linker scripts. It is consumed by the
  linker at build time and **never installed as OS packages, never on `PATH`, and
  never executed as the container's runtime libc.**
- So it does **not** appear in the image's OS package inventory, and it does not bring
  along an older base's wider userspace of packages.
- The **running** userspace is modern trixie (glibc 2.41) - what scanners inventory
  and what receives security updates.

That is the distinction between linking against an old libc (a contained, file-level
build input) and running an old distro as the OS (a broader, system-wide surface).

## What remains in the new image (and why)

- **Go toolchain**: Trivy attributes Go *stdlib* advisories to the pinned go1.25.10.
  These are unavoidable - the plugin **must** be built with the Gateway's exact Go
  version (ABI requirement). They are identical to the Gateway's own exposure.
- **trixie base + gcc/binutils + cross gcc**: the irreducible compile toolchain.
- **glibc-2.31 sysroot files**: build inputs (see above).

## Further hardening (documented, not yet applied)

- Drop `g++`/C++ cross unless C++ CGO plugins are required (`ARG WITH_CXX=0`).
- Switch `BASE_IMAGE` to `cgr.dev/chainguard/wolfi-base` for a near-zero-CVE,
  continuously-rebuilt glibc base (trade-off: rolling, pin by digest).
- Strip debug info from the baked Gateway self-test binary, or omit it from the
  shipped image (build it in a throwaway stage used only for CI load-tests).
- `--no-install-recommends` everywhere (already applied) + remove `apt`/lists in the
  final layer.

## Supply-chain artifacts
- **SBOM and scan reports are generated, not committed.** Reproduce locally with
  `task sbom` (Syft: SPDX + CycloneDX) and `task scan` / `scripts/cve-compare.sh`
  (Trivy); output lands in `artifacts/` (gitignored).
- **In CI**, the publish step attaches an SBOM and SLSA provenance to the pushed image
  (`provenance: true`, `sbom: true` in `build.yml` / `build-wolfi.yml`).
- **Signing** (cosign) and digest pinning are publish-time steps run by your pipeline
  with your own credentials.
