# Security note - a hardened, minimal base for plugin compilation

This note explains why a purpose-built plugin-compiler image produces far fewer
CVE-scanner findings than a general-purpose Gateway release builder, and why that
reduction is structural rather than cosmetic.

## Headline: the two-number story (measured, Trivy v5.13.0)

The single most important framing is what happens under `--ignore-unfixed` - dropping
advisories with no fix available. **Every variant collapses to the same ~27 findings, all of
it the shared Go stdlib.** The *actionable, fixable* surface is identical across variants:

| Variant | Base | Raw full scan (CRIT / HIGH / total) | `--ignore-unfixed` (actionable) |
|---|---|---:|---:|
| Default | busybox-glibc, native | ~1 / ~49 / ~1000 | **~27 (Go stdlib)** |
| `-x` | busybox-glibc + cross | ~1 / ~49 / ~1100 | **~27 (Go stdlib)** |
| `-wolfi` | Chainguard Wolfi, native | 0 / 9 / 27 | **~27 (Go stdlib)** |

The large raw counts on the busybox-glibc variants are almost entirely **unfixed distro noise**:
the won't-fix `linux-libc-dev` kernel-UAPI-header attribution and (on `-x`) the cross-target
binutils BFD-parser advisories. In a build-time image - no kernel, no runtime network services -
that noise is benign. "Unfixed" is not "harmless" in general, but for this image it genuinely is.
The Go stdlib 27 is shared by every variant because it is the pinned Go toolchain, which matches
the Gateway's own Go (an ABI requirement).

For context, the official `tyk-plugin-compiler` (a goreleaser-cross image that also builds and
packages the Gateway) carries a much broader toolchain for its wider role, so a raw
package-count comparison is not apples-to-apples; a focused plugin-compiler base carries less.

### What the lone CRITICAL actually is
On the busybox-glibc variants the single CRITICAL is **`linux-libc-dev`** - a Linux *kernel* CVE
attributed to the kernel-UAPI-headers package. No kernel runs in a build image; the package is
`#include`-only, required for native CGO's `<linux/errno.h>` (and the boringcrypto FIPS path), so
it is kept and **honestly reported, not suppressed**. The `-wolfi` variant carries no kernel
headers and reports 0 CRITICAL.

### The `-x` variant adds only LOW noise
The `-x` cross variant is the same busybox-glibc base **plus C cross toolchains**. Its
criticals/highs are unchanged from the default; the extra ~100 raw findings are all **LOW**
(cross-target binutils BFD-parser advisories) and are dropped entirely under `--ignore-unfixed`.

### Package trimming on the busybox-glibc base

Both busybox-glibc variants ship an unused-package purge so the scan reflects what is present:

- Purges the packages the compiler never uses at runtime, files and all (not just a manifest
  entry): the perl family (`perl`, `perl-base`, `perl-modules`, and the orphaned `libperl`
  runtime - its only consumer was perl), plus `gpgv` and `ncurses-base/bin/term`.
- Omits `curl` - Go is fetched at build time via BuildKit `ADD` + `sha256sum` (trust anchor
  unchanged: go.dev + the pinned checksum).
- Reconciles the distroless `/var/lib/dpkg/status.d/` scanner manifest **only** for packages
  actually removed - never clearing an entry whose files remain (that would hide a real package).

What stays does so because it is in use: `linux-libc-dev` (native CGO headers),
`libexpat`/`libcurl`/`libssh2` (git's HTTPS/VCS transport), the essential
`libssl3`/`openssl`/`libsqlite3`, `libtinfo6` (bash) and the Go `stdlib`. Nothing is suppressed
or VEX'd. See [`base-images.md`](base-images.md) for the full reasoning.

## Why the findings drop (and why it is structural)

1. **Current, supported base.** This image uses a modern, continuously-patched hardened
   glibc base (DHI busybox-glibc), the same libc lineage as the Gateway runtime. Many
   MEDIUM/LOW findings on an older base are "fixed in a newer version" advisories that a
   current base does not carry. The release builder is on an older Debian, which carries more.

2. **Only the toolchain plugin builds use.** This image installs gcc/binutils for the
   plugin's C/CGO needs. It does not include clang/LLVM. The release builder carries
   clang/LLVM for its own purposes, but plugin compilation does not use them.

3. **Cross toolchains scoped to plugin targets, and only when needed.** The default
   variant is native-only and carries no cross toolchains at all. The `-x` variant carries
   C cross toolchains for the architectures plugins target (amd64/arm64/s390x). The release
   builder also builds the Gateway itself for additional targets (for example
   powerpc64le), so it reasonably carries more.

4. **No release/packaging tooling.** Release automation and packaging dependencies
   (the goreleaser and dpkg-cross Perl/HTTP libraries) are part of the Gateway's
   release job, not of compiling a plugin, so they are absent here.

5. **Small, auditable surface.** Package managers and caches are cleaned; the image
   keeps only what `build.sh` uses (bash, jq, gcc, binutils, file, make, Go; git is
   optional via `WITH_GIT`).

## glibc compatibility as a sysroot, not the OS - the central architectural point

CGO plugins need **glibc symbol compatibility** with the Gateway runtime. This image
provides that without running an old OS:

- The glibc compatibility sysroot exists **only as files under `/opt/tyk/sysroots/`** -
  `libc`, the dynamic loader, `crt*.o`, headers, and linker scripts. It is consumed by
  the linker at build time and **never installed as OS packages, never on `PATH`, and
  never executed as the container's runtime libc.**
- So it does **not** appear in the image's OS package inventory, and it does not bring
  along an older base's wider userspace of packages.
- The **running** userspace is the modern hardened base's glibc - what scanners inventory
  and what receives security updates.

That is the distinction between linking against an old libc (a contained, file-level
build input) and running an old distro as the OS (a broader, system-wide surface).
The default target is documented in [`glibc-targets.md`](glibc-targets.md).

## What remains in the new image (and why)

- **Go toolchain**: Trivy attributes Go *stdlib* advisories to the pinned go1.25.10.
  These are unavoidable - the plugin **must** be built with the Gateway's exact Go
  version (ABI requirement). They are identical to the Gateway's own exposure.
- **busybox-glibc base + gcc/binutils (+ cross gcc on `-x`)**: the irreducible compile toolchain.
- **glibc-2.17 sysroot files**: build inputs (see above).

## Further hardening (some baked in, some opt-in)

The unused-package purge + manifest reconcile + curl removal is **baked into both busybox-glibc
variants** (default and `-x`), and the **`-wolfi`** tag is the Chainguard base switch (see
[`base-images.md`](base-images.md)). The rest remain opt-in:

- Drop `g++`/C++ cross unless C++ CGO plugins are required (`ARG WITH_CXX=0`).
- Switch `BASE_IMAGE` to `cgr.dev/chainguard/wolfi-base` for a near-zero-CVE,
  continuously-rebuilt glibc base (trade-off: rolling, pin by digest) - **shipped as `-wolfi`**.
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
