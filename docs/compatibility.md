# Compatibility and tested evidence

This page explains why a plugin must match its Gateway exactly, and records what was
tested for the v5.13.0 images. The same checks run in CI before any image is published.

## The rule: plugins are bound to one Gateway build

Go's `-buildmode=plugin` loader rejects a plugin unless it was built with the **same Go
toolchain** and the **same versions of every package shared with the host**. The Gateway
is the host, so a plugin for Gateway `vX.Y.Z` must be compiled against that release's
exact Go version and module graph.

`compile-tyk-plugin:vX.Y.Z` guarantees this by building your plugin in a Go workspace
against the vendored Gateway source at the same commit. The modernization changes only
the OS, the C toolchain, and the C-link sysroot. It never changes the Go module graph,
so the ABI match is identical to the official compiler's.

## What stays compatible

| Dimension | Plugin (this compiler) | Gateway runtime | Match |
|---|---|---|---|
| Go toolchain | go1.25.10 (pinned to the release) | go1.25.10 | exact (required) |
| Module graph | vendored at the Gateway commit | same commit | identical |
| Build tags / flags | `-trimpath`, edition tags, `-buildmode=plugin` | same tags | yes |
| CGO | enabled | enabled | yes |
| Dynamic linker | pinned per arch | same | yes |
| glibc symbol floor | <= 2.17 (see below) | provides 2.41 | yes, far below |

## glibc floor

A binary that requires glibc symbols up to version *N* loads on any glibc *>= N*. The
Gateway runtime ships glibc 2.41, so a plugin loads as long as its highest required
symbol is <= 2.41 - but the runtime is not the only constraint. Customers also run the
Gateway **natively on older OSes** (notably RHEL 7, glibc 2.17, in Extended Life Cycle
Support), and a plugin must load there too.

So this compiler links every plugin against a **glibc-2.17 sysroot by default** - the
RHEL 7 / CentOS 7 ABI, sourced from the `manylinux2014` images. That is also the glibc
the Gateway's own cgo is linked against (its binaries require <= 2.16), so the plugin
floor simply matches the Gateway. The result is a plugin that loads on everything from
RHEL 7 upward, at no behavioral cost. Measured ceilings per target (2.17 sysroot):

| Target | Highest required glibc symbol |
|---|---|
| linux/amd64 | 2.3.2 (measured) |
| linux/arm64 | <= 2.17 |
| linux/s390x | <= 2.17 |

### Opting into a higher floor

Higher floors are an advanced escape hatch for plugins whose own C/C++ code needs newer
glibc APIs. They reduce portability and are not needed for normal Gateway images. See
[`glibc-targets.md`](glibc-targets.md).

## Tested load matrix (v5.13.0)

Every cell below was built with this compiler and loaded into the matching-arch,
matching-edition `tyk-gateway` image. A plugin that injects a response header was
confirmed to run end to end (`GET /goplugin/headers` returns `Foo: Bar`).

| Edition | Build tags | amd64 | arm64 | s390x |
|---|---|---|---|---|
| CE | `goplugin` | loads | loads | loads |
| EE | `goplugin,ee` | loads | loads | not published by Tyk |
| EE-FIPS | `goplugin,ee,fips,fips140v1.0` | loads | loads | not published by Tyk |

Cross-compilation was exercised in both directions (amd64 host building arm64/s390x and
arm64 host building amd64/s390x); a foreign-architecture object loading at all is itself
proof of a correct build, because `plugin.Open` rejects a wrong-machine or wrong-endian
object outright. EE and EE-FIPS publish amd64/arm64 only today; the compiler reads each
edition's published architectures from the Gateway manifest, so if Tyk adds s390x for
those editions a rebuild picks it up automatically (see `docs/maintenance.md`).

## Editions are not interchangeable

A CE-built plugin is rejected by the FIPS Gateway (`crypto/internal/fips140` mismatch),
and an OSS-built plugin that imports an `ee`-affected package can fail on an EE Gateway.
Build for the edition you will run by passing `-e EDITION=ce|ee|ee-fips`. See
`docs/fips.md`.

## Why the gate is the backstop

Pure ELF or symbol inspection cannot detect a shared transitive-dependency version skew,
which is the most common cause of a silent ABI mismatch. CI therefore builds a real
plugin and loads it into the actual Gateway for every edition and architecture before
publishing. If any combination fails to load, the release does not ship.
