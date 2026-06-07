#!/usr/bin/env bash
# Resolve releases.yml (the support policy) into concrete version sets, for a given Gateway
# version space (git tags INTERSECT published gateway images = "buildable"). SINGLE source of
# truth shared by watch.yml (build + re-stack) and prune.yml (retention) so they cannot drift.
#
# Emits to stdout, one record per line:
#   SETTING patch_depth <n>
#   SETTING snapshot_retention_days <n>
#   ACTIVE  vX.Y.Z      # base-CVE-updated: moving tag re-stacked, dated snapshots kept N days
#   FROZEN  vX.Y.Z      # kept + buildable, but NO base updates: latest snapshot only
# KEEP = ACTIVE + FROZEN. Build set = ACTIVE + FROZEN. Base re-stack set = ACTIVE only.
# Anything in our registry NOT emitted here is out-of-policy (prune deletes it).
#
# Requires: python3, crane, git. Env: RELEASES_FILE, GW_CE_REPO, SOURCE_REPO.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="${RELEASES_FILE:-$HERE/releases.yml}"
GW_CE_REPO="${GW_CE_REPO:-tykio/tyk-gateway}"
SOURCE_REPO="${SOURCE_REPO:-TykTechnologies/tyk}"
SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+$'
LINE_RE='^[0-9]+\.[0-9]+$'

[ -f "$POLICY" ] || { echo "ERROR: policy file not found: $POLICY" >&2; exit 1; }
py() { python3 -c "import yaml; d=yaml.safe_load(open('$POLICY')) or {}; $1"; }
read_list() { py "print('\n'.join(str(x) for x in (d.get('$1') or [])))"; }
read_val()  { py "print(d.get('$1',''))"; }

PATCH_DEPTH="$(read_val patch_depth)"; PATCH_DEPTH="${PATCH_DEPTH:-3}"
RET_DAYS="$(read_val snapshot_retention_days)"; RET_DAYS="${RET_DAYS:-14}"
echo "SETTING patch_depth $PATCH_DEPTH"
echo "SETTING snapshot_retention_days $RET_DAYS"

# buildable = proper-semver git tags that ALSO have a published gateway image (shell-agnostic
# intersection via temp files, not <(...)).
git_tags="$(git ls-remote --tags --refs "https://github.com/${SOURCE_REPO}.git" 2>/dev/null | sed 's#.*refs/tags/##' | grep -E "$SEMVER" | sort -uV || true)"
reg_tags="$(crane ls "$GW_CE_REPO" 2>/dev/null | grep -E "$SEMVER" | sort -uV || true)"
gt="$(mktemp)"; rt="$(mktemp)"; printf '%s\n' "$git_tags" >"$gt"; printf '%s\n' "$reg_tags" >"$rt"
buildable="$(grep -Fxf "$rt" "$gt" | sort -uV || true)"; rm -f "$gt" "$rt"
[ -n "$buildable" ] || { echo "ERROR: empty buildable set (git/registry lookup failed)" >&2; exit 1; }
has()        { printf '%s\n' "$buildable" | grep -qx "$1"; }
patches_of() { printf '%s\n' "$buildable" | grep -E "^v$(printf '%s' "$1" | sed 's/\./\\./g')\." | sort -V; }

active=""; frozen=""
# maintained = whole minor lines: every patch kept; newest patch_depth ACTIVE, the rest FROZEN.
for L in $(read_list maintained); do
  printf '%s' "$L" | grep -qE "$LINE_RE" || { echo "WARN: maintained '$L' is not a minor line (X.Y), skipping" >&2; continue; }
  pall="$(patches_of "$L")"
  [ -n "$pall" ] || { echo "WARN: maintained line '$L' has no buildable patches" >&2; continue; }
  pact="$(printf '%s\n' "$pall" | tail -n "$PATCH_DEPTH")"
  active="$active $pact"
  for v in $pall; do printf '%s\n' "$pact" | grep -qx "$v" || frozen="$frozen $v"; done
done
# maintained_extra = exact one-off versions, kept ACTIVE.
for v in $(read_list maintained_extra); do
  printf '%s' "$v" | grep -qE "$SEMVER" || { echo "WARN: maintained_extra '$v' is not vX.Y.Z, skipping" >&2; continue; }
  has "$v" && active="$active $v" || echo "WARN: maintained_extra '$v' not buildable, skipping" >&2
done
# retired = out of support, FROZEN: a line "X.Y" -> keep its tip only; a version "vX.Y.Z" -> keep it.
for r in $(read_list retired); do
  if printf '%s' "$r" | grep -qE "$LINE_RE"; then
    tip="$(patches_of "$r" | tail -n 1)"; [ -n "$tip" ] && frozen="$frozen $tip" || echo "WARN: retired line '$r' has no buildable patches" >&2
  elif printf '%s' "$r" | grep -qE "$SEMVER"; then
    has "$r" && frozen="$frozen $r" || echo "WARN: retired '$r' not buildable, skipping" >&2
  else
    echo "WARN: retired '$r' is neither a line (X.Y) nor a version (vX.Y.Z), skipping" >&2
  fi
done

active="$(printf '%s\n' $active | grep -E "$SEMVER" | sort -uV | uniq || true)"
frozen="$(printf '%s\n' $frozen | grep -E "$SEMVER" | sort -uV | uniq || true)"
for v in $active; do echo "ACTIVE $v"; done
for v in $frozen; do printf '%s\n' "$active" | grep -qx "$v" || echo "FROZEN $v"; done   # ACTIVE wins
