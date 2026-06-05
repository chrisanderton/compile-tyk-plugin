# Editions (CE / EE / EE-FIPS) - one compiler image, an EDITION flag

Tyk ships gateway editions from the **same commit**, differing only by Go build config.
Build the plugin for the **edition of the Gateway you will run it in** via `-e EDITION=`:

| `EDITION` | Gateway image | build tags | architectures | flag |
|---|---|---|---|---|
| `ce` *(default)* | `tyk-gateway` | `goplugin` | amd64/arm64/s390x | *(none)* |
| `ee` | `tyk-gateway-ee` | `goplugin,ee` | amd64/arm64 | `-e EDITION=ee` |
| `ee-fips` | `tyk-gateway-fips` | `goplugin,ee,fips,fips140v1.0` + `GOFIPS140` | amd64/arm64 | `-e EDITION=ee-fips` (or `-e FIPS=1`) |

```bash
docker run --rm -e EDITION=ee      -v "$PWD:/plugin-source" <you>/compile-tyk-plugin:v5.13.0 my-plugin.so
docker run --rm -e EDITION=ee-fips -v "$PWD:/plugin-source" <you>/compile-tyk-plugin:v5.13.0 my-plugin.so
```

Each edition's plugin loads into its matching Gateway, and a CE plugin is rejected by the
FIPS Gateway (`crypto/internal/fips140` mismatch): editions are not freely
interchangeable. This is checked in CI before publish (see `docs/compatibility.md`).

**Why an EDITION flag (not "OSS-works-everywhere"):** the `ee` tag gates enterprise
code and **EE keeps adding middleware**, so an OSS-built plugin that imports an
`ee`-affected package can fail `plugin.Open` on an EE gateway. Matching the edition is
the safe, future-proof choice. (FIPS additionally swaps the crypto module.) `FIPS=1`
remains as a back-compat alias for `EDITION=ee-fips`.

## Why one image is enough (no per-edition compiler)
The FIPS gateway is built from the **same commit and same Go version** as the standard
gateway - FIPS is just a different **build configuration**, not different source. So
the compiler (which already vendors that commit's source and pins that Go version)
just needs the FIPS build switches. They're already plumbed (`GOFIPS140`, `BUILD_TAG`,
`GOEXPERIMENT`) and `go build` reads them from the environment.

## The settings are baked per release (and auto-detect the mechanism)
The FIPS mechanism **changes across versions**, so nothing is hardcoded:
- **Newer Go (>=1.24)** - e.g. Gateway v5.13.0 - uses the **native FIPS 140-3 module**:
  `GOFIPS140=v1.0.0` + tags `ee,fips` (Go re-adds `fips140vX.Y` automatically) +
  runtime `GODEBUG=fips140=on`.
- **Older Go/gateways** used **`GOEXPERIMENT=boringcrypto`** (CGO, historically amd64-only).

`scripts/resolve-gateway.sh` reads the **edition Gateway binaries** (`tyk-gateway-ee`,
`tyk-gateway-fips`) and derives the per-edition settings - `EE_BUILD_TAG`, and for FIPS
whichever applies (`FIPS_GOFIPS140` / `FIPS_GOEXPERIMENT` / `FIPS_BUILD_TAG`). CI bakes
them into the image as `TYK_EE_*` / `TYK_FIPS_*` env; `build.sh` applies the set named
by `EDITION`. So a v5.13.0 image does native FIPS; a future boringcrypto-era build
would do boringcrypto - same `EDITION=ee-fips` flag, no image or workflow change.

For v5.13.0, the resolver derives:
```
EE_AVAILABLE=true   EE_BUILD_TAG=ee
FIPS_AVAILABLE=true FIPS_GOFIPS140=v1.0.0 FIPS_GOEXPERIMENT= FIPS_BUILD_TAG=ee,fips
```

## Guarantees & limits
- **Validated at build time**: `validate-plugin.sh` fails the build if the plugin
  doesn't carry the edition's markers - the `ee` tag for `ee`/`ee-fips`, and FIPS crypto
  (`GOFIPS140=...`/boringcrypto) for `ee-fips`. No silent wrong-edition output.
- **Gated before publish**: `build.yml` runs a per-edition load test (plugin built for
  each available edition -> its matching Gateway) on **amd64 and arm64**. A release
  publishes only if **every** available edition loads.
- **Per-edition architectures are data-driven**, not hardcoded: the published architectures are read
  from each edition Gateway's manifest and baked in (`TYK_{CE,EE,FIPS}_ARCHS`, labels
  `io.ctp.*-archs`). Today EE/FIPS ship amd64/arm64 only (so `EDITION=ee|ee-fips` with
  `GOARCH=s390x` fails fast), while `ce` also covers s390x - **but if Tyk adds s390x
  (or any arch) to EE/FIPS, a rebuilt compiler allows and gates it automatically, no
  code change.** The watcher detects the arch-set change and triggers that rebuild.
- **No edition variant for a release** (e.g. versions predating the EE/FIPS gateways):
  that `EDITION` fails fast (`TYK_EE_AVAILABLE`/`TYK_FIPS_AVAILABLE=false`).
- The image is identical for all editions - edition is purely the runtime flag, so
  there is **one image to maintain, scan, and sign**, covering CE/EE/EE-FIPS.
