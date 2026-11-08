#!/usr/bin/env bash
# Test the patched Dex source: gofmt on patched Go files, go vet and the full
# upstream unit test suite (database-backed storage tests skip without their
# environment), plus explicit runs of the PathOps audience and delegation
# tests.
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

echo "test: PathOps session cookie key test"
out=$(go test ./cmd/dex/ -count=1 -run '^TestSessionCookieKeyFromEnv$' -v)
grep -q -- '--- PASS: TestSessionCookieKeyFromEnv ' <<< "$out" \
  || { echo "test: TestSessionCookieKeyFromEnv did not run and pass" >&2; exit 1; }

echo "test: PathOps delegation tests"
out=$(go test ./server/ ./server/delegation/ ./storage/kubernetes/ -count=1 -run 'Delegation|NewPolicy|AudiencePattern|Consent' -v)
echo "$out" | grep -E -- '^--- (PASS|FAIL)'
for t in TestDelegationFlow TestDelegationOperationsAreSeparate TestDelegationPushedRequestChecks TestDelegationConsent TestDelegationSessions \
  TestDelegationCanonical TestNewPolicy TestConsentGroupsByTool TestConsentBuildAndPush TestDelegationFieldRoundTrip; do
  grep -q -- "--- PASS: $t " <<< "$out" || { echo "test: $t did not run and pass" >&2; exit 1; }
done

echo "test: PathOps BUILD_AND_PUSH consent screen and registry token tests"
out=$(go test ./server/ ./server/registry/ ./server/grants/ ./server/templates/ -count=1 \
  -run 'Registry|TestIssue|TestClient|TestNewValidates|TestDelegationTemplate' -v)
echo "$out" | grep -E -- '^--- (PASS|FAIL)'
for t in TestIssue TestIssueDenied TestClient TestNewValidates TestRegistryToken TestHandleTokenExchangeRegistry \
  TestDelegationTemplateBuildAndPush; do
  grep -q -- "--- PASS: $t " <<< "$out" || { echo "test: $t did not run and pass" >&2; exit 1; }
done

echo "test: OK"
