# Air-gapped plugin compilation

## TL;DR
The compiler's **only** runtime network dependency is the **Go module proxy**.
Everything else is baked into the image (Go toolchain, gcc/binutils, the glibc
sysroots, the vendored Gateway source) and `GOTOOLCHAIN=local` prevents Go from ever
downloading a toolchain. There is **no `apt`/OS download at plugin-build time.**

So to run in an air-gapped network you only have to give Go a **local source of
modules**. Two supported options, both standard Go mechanisms - **no image rebuild**:

| Option | How | Best for |
|---|---|---|
| **A. Internal module proxy** | `-e GOPROXY=https://goproxy.internal -e GOSUMDB=off` | Org-wide, repeatable (Athens / Artifactory / Nexus) |
| **B. Pre-populated module cache** | warm a cache once online, ship it in, `-e GOPROXY=file://... -e GOSUMDB=off --network none -v cache:/go/pkg/mod` | One-off / fully offline boxes |

> Fetching the dependency graph from `proxy.golang.org` at build time is the standard
> Go behavior, shared with the official compiler. The module cache is deliberately not
> baked into the image: doing so would add several GB and tie the image to one
> dependency snapshot. Instead, point Go at a local module source as shown below.

## What actually gets downloaded at runtime
When you run the compiler, `build.sh` does a Go **workspace** build of your plugin
against the in-image Gateway source. To compile, Go needs the **source of every
module** in the combined dependency graph (the Gateway's deps + your plugin's own
third-party deps). With the default `GOPROXY=https://proxy.golang.org,direct`, Go
fetches any module not already cached - that's the (only) egress to eliminate.

## Option A - internal Go module proxy (recommended)
Stand up a self-hosted Go proxy inside the air-gapped zone and pre-seed it:

- **Athens** (`gomods/athens`), **JFrog Artifactory** (Go Registry), or **Nexus**
  (Go proxy repo) all speak the Go module proxy protocol.
- Seed it from a connected mirror/CI by building the Gateway + a representative
  plugin once (or `go mod download` against their `go.mod`s) so every required
  `*.mod`/`*.zip` is cached in the proxy.

Then run the compiler pointed at it:
```bash
docker run --rm \
  -e GOPROXY=https://goproxy.internal/  \
  -e GOSUMDB=off \                       # sum.golang.org is unreachable; go.sum still verifies integrity
  -v "$PWD:/plugin-source" \
  compile-tyk-plugin:vX.Y.Z my-plugin.so
```
(If your proxy enforces auth, add `-e GONOSUMCHECK=1` only if required, and provide
`GOPROXY=https://user:token@goproxy.internal/`. Prefer an internal `GONOSUMDB`/`GOSUMDB`
if you run an internal checksum DB.)

## Option B - pre-populated module cache (fully offline)
Warm a module cache **once on a connected machine** by building your actual plugin
(this captures the Gateway deps **and** your plugin's own deps):
```bash
docker volume create tyk-mod-cache
docker run --rm \
  -v tyk-mod-cache:/go/pkg/mod \
  -v "$PWD/my-plugin:/plugin-source" \
  compile-tyk-plugin:vX.Y.Z my-plugin.so          # online; populates the volume
```
Ship that cache into the air-gapped host (move the volume, or export
`/go/pkg/mod/cache/download` as a tarball). Then build with **no network at all**,
using the cache as a `file://` proxy:
```bash
docker run --rm \
  --network none \
  -e GOPROXY=file:///go/pkg/mod/cache/download \
  -e GOSUMDB=off \
  -v tyk-mod-cache:/go/pkg/mod \
  -v "$PWD/my-plugin:/plugin-source" \
  compile-tyk-plugin:vX.Y.Z my-plugin.so          # offline
```
With a warmed cache, this produces a valid plugin under `--network none`: correct Go
version, the same dependency versions as the Gateway, and a glibc floor of 2.31. The
build validator runs as usual and fails the build on any mismatch.

### Notes
- **Do NOT pass `GOFLAGS=-mod=mod`** - it's illegal in workspace mode (`-mod may only
  be readonly or vendor`). The `file://`/proxy approach works in the default readonly
  workspace mode, which is why it's preferred over a bare `GOPROXY=off`.
- **`GOSUMDB=off`** is needed because `sum.golang.org` is unreachable; module
  integrity is still checked against `go.sum`/cached hashes. For stricter posture,
  run an internal checksum database and point `GOSUMDB`/`GONOSUMDB` at it.
- **Your plugin's own third-party deps** (anything beyond the Gateway's graph + std
  lib) must be in the proxy/cache too - warming with the *real* plugin (Option B) or
  seeding the proxy with it (Option A) captures them automatically.
- Per-arch is identical: cross-compiling (`-e GOARCH=arm64|amd64|s390x`) uses the same
  module cache (the C cross-toolchain + sysroots are already in the image).
- The cache is reusable across builds and plugins; refresh it only when the Gateway
  version (and thus its `go.mod`) changes.
