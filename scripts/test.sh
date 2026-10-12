#!/usr/bin/env bash
# Test the patched Dex source: gofmt on patched Go files, go vet and the full
# upstream unit test suite (database-backed storage tests skip without their
# environment), plus an explicit run of the PathOps audience test.
#
# usage: scripts/test.sh   (set SKIP_PREPARE=1 to reuse an already prepared tree)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${PATHOPS_DEX_WORKDIR:-$ROOT/.work}/dex"

[ "${SKIP_PREPARE:-0}" = "1" ] || "$ROOT/scripts/prepare-source.sh"
cd "$SRC"

echo "test: gofmt on Go files touched by the patches"
mapfile -t changed < <({ git diff --name-only; git ls-files --others --exclude-standard; } | grep '\.go$' | sort -u)
if [ "${#changed[@]}" -gt 0 ]; then
  unformatted=$(gofmt -l "${changed[@]}")
  [ -z "$unformatted" ] || { echo "test: gofmt needed for: $unformatted" >&2; exit 1; }
fi

echo "test: go vet ./..."
go vet ./...

echo "test: go test ./... (includes ./connector/... and ./server/...)"
go test ./...

echo "test: PathOps subject-token audience test"
out=$(go test ./connector/oidc/ -count=1 -run '^TestTokenIdentitySubjectTokenAudiences$' -v)
echo "$out" | grep -E -- '--- (PASS|FAIL)'
grep -q -- '--- PASS: TestTokenIdentitySubjectTokenAudiences ' <<< "$out" \
  || { echo "test: TestTokenIdentitySubjectTokenAudiences did not run and pass" >&2; exit 1; }

echo "test: OK"
