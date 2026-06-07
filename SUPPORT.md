# Support & lifecycle policy

This compiler is a **build tool**: you pull `compile-tyk-plugin:<gateway-version>` to compile a
Go plugin for that exact Gateway. Because `plugin.Open` is patch-exact (Go version + vendored
source must match), a compiler is published **per Gateway patch release**.

The supported set is declared, in the open, in [`releases.yml`](releases.yml). Changing support
is a reviewed change to that file - the git history is the lifecycle audit trail.

## What's supported

| Class (in `releases.yml`) | Meaning | Base-CVE updates | Availability |
|---|---|---|---|
| **maintained** - whole minor lines (latest, LTS, LTS-1) | every patch of the line has a builder | the newest `patch_depth` patches (default 3) stay current; older patches **freeze** | full line |
| **maintained_extra** - specific versions | a one-off you want kept current (e.g. a key customer pin) | yes | that version |
| **retired** - lines or versions | out of support, kept only so you can build to upgrade off it | no (frozen) | a retired *line* keeps its final patch; a retired *version* keeps itself |
| *(not listed)* | unsupported | - | removed |

## Tags & reproducibility

For each supported version `V` and variant (default = Docker Hardened Image; `-wolfi`):

- **`:V`** (and `:V-wolfi`) - **moving**, always the latest-patched build. **Track this for security currency.**
- **`:V-YYYYMMDD`** - **immutable** snapshot. Retained **`snapshot_retention_days`** (default **14 days**)
  for actively-updated versions; frozen/retired versions keep only their latest snapshot. Pin these
  (or a digest) for a reproducible point-in-time build.
- **Editions** are selected at build time (`-e EDITION=ce|ee|ee-fips`); **architectures** via `-e GOARCH`
  (amd64/arm64/s390x). A higher glibc floor is on the opt-in `:V-glibc2.31` tags.

**Guarantee:** because a compiler is fully reproducible from its Gateway version, **any supported
version is always (re)buildable on request** - a bounded snapshot window costs you nothing.

## Currency

Maintained/extra (ACTIVE) builders are rebuilt whenever the hardened base ships a CVE fix, so the
moving tag stays low-CVE. The DHI and Wolfi bases are tracked independently. Each image carries an
SPDX SBOM + SLSA provenance attestation.

## Lifecycle (how to change support)

Open a PR against `releases.yml`:
- **New LTS / new latest** -> add its line to `maintained`.
- **A customer runs an older or out-of-line patch** -> add the exact version to `maintained_extra`
  (kept current) or `retired` (kept available, frozen).
- **A line ages out** -> move it to `retired` - it collapses to its final patch (an upgrade aid),
  the rest is pruned.
- **Truly done** -> remove the entry; the pruner deletes it.

Deprecations are deliberate and visible in the file's history; we aim to give **>=30 days** notice
before removing a previously-supported version.
