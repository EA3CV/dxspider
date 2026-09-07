#!/bin/sh
set -eu
BASE="${1:-http://127.0.0.1:8080}"
echo '== health =='
curl -fsS "$BASE/healthz"
printf '\n== write methods must be rejected ==\n'
for method in POST PUT PATCH DELETE; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X "$method" "$BASE/test")
  printf '%-6s %s\n' "$method" "$code"
  [ "$code" = 405 ] || exit 3
done
echo 'RX-only HTTP check: PASS'
