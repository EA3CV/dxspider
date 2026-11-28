#!/bin/sh
set -eu
BASE="${1:-http://127.0.0.1:7380}"
FAIL=0

fail() {
  echo "FAIL: $*" >&2
  FAIL=1
}

echo '== health =='
curl -sS "$BASE/healthz" || true
printf '\n== readiness ==\n'
curl -sS "$BASE/readyz" || true

echo '== version =='
VERSION_JSON=$(curl -fsS "$BASE/version.json" || true)
printf '%s\n' "$VERSION_JSON"
printf '%s' "$VERSION_JSON" | grep -q '"version"' || fail "version.json has no version field"

echo '== security headers =='
HEADERS=$(curl -fsS -D - -o /dev/null "$BASE/" || true)
for h in Content-Security-Policy X-Content-Type-Options Referrer-Policy \
         Permissions-Policy X-Frame-Options Cross-Origin-Opener-Policy; do
  if printf '%s' "$HEADERS" | grep -qi "^$h:"; then
    printf '%-32s present\n' "$h"
  else
    fail "missing header $h"
  fi
done
printf '%s' "$HEADERS" | grep -qi "frame-ancestors 'none'" ||
  fail "CSP does not set frame-ancestors 'none'"
printf '%s' "$HEADERS" | grep -qi "object-src 'none'" ||
  fail "CSP does not set object-src 'none'"

echo '== mutating HTTP methods must be rejected =='
for method in POST PUT PATCH DELETE; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X "$method" "$BASE/test")
  printf '%-6s %s\n' "$method" "$code"
  [ "$code" = 405 ] || fail "$method returned $code, expected 405"
done

if [ "$FAIL" -ne 0 ]; then
  echo 'HTTP surface check: FAIL'
  exit 3
fi
echo 'HTTP surface check: PASS'
