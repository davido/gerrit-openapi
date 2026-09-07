#!/usr/bin/env bash
#
# Refresh the published OpenAPI documents from a Gerrit checkout's build outputs.
#
# gerrit-openapi is a distribution point, not a source of truth: every document here is
# a byte-for-byte copy of a Gerrit build output. Run this to re-sync after a spec change,
# then review the diff, commit, and -- at a release -- tag (e.g. v3.15.0) so consumers
# can pin an immutable spec.
#
# Usage: ./update.sh [path-to-gerrit-checkout]     (default: ../gerrit6)
set -euo pipefail
cd "$(dirname "$0")"

SRC=${1:-../gerrit6}
[ -d "$SRC" ] || { echo "error: gerrit checkout not found: $SRC" >&2; exit 1; }
SRC=$(cd "$SRC" && pwd)

# core per-area slices (target //tools/openapi:openapi_<name>_json)
DOMAINS=(access accounts changes config flow groups plugins projects)
# plugins with their own OpenAPI document: "<package-dir> <target-name>"
PLUGINS=(
  "checks checks_openapi_json"
  "code-owners code_owners_openapi_json"
)

echo "1/3 build the OpenAPI documents in $SRC"
TARGETS="//tools/openapi:openapi_json"
for d in "${DOMAINS[@]}"; do TARGETS="$TARGETS //tools/openapi:openapi_${d}_json"; done
for entry in "${PLUGINS[@]}"; do
  set -- $entry
  TARGETS="$TARGETS //plugins/$1:$2"
done
( cd "$SRC" && bazel build $TARGETS 2>&1 | tail -1 )

BIN="$SRC/bazel-bin"
echo "2/3 copy build outputs into the published tree"
cp "$BIN/tools/openapi/all-domain-openapi.generated.json" core/openapi.json
for d in "${DOMAINS[@]}"; do
  cp "$BIN/tools/openapi/${d}-openapi.generated.json" "core/domains/${d}.json"
done
for entry in "${PLUGINS[@]}"; do
  set -- $entry
  mkdir -p "plugins/$1"
  cp "$BIN/plugins/$1/$2.generated.json" "plugins/$1/openapi.json"
done
# bazel outputs are read-only; the published copies are normal files.
chmod -R u+w core plugins

echo "3/3 sanity: the domain slices must partition the monolith"
python3 - <<'PY'
import glob, json, sys
mono = len(json.load(open("core/openapi.json")).get("paths", {}))
areas = sum(len(json.load(open(f)).get("paths", {})) for f in glob.glob("core/domains/*.json"))
ver = json.load(open("core/openapi.json")).get("info", {}).get("version")
ok = mono == areas
print(f"   core paths={mono}  sum(core/domains)={areas}  version={ver}  "
      f"[{'partition OK' if ok else 'PARTITION MISMATCH'}]")
sys.exit(0 if ok else 1)
PY

echo
echo "done. Review the diff and commit; at a release, tag to match info.version:"
git status --short core plugins || true
