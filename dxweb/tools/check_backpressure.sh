#!/bin/sh
set -eu
URL=${1:-http://127.0.0.1:8080/healthz}
echo "Health:"
curl -fsS "$URL" || true
echo
echo "Watch these counters during slow-client tests:"
echo "fanout_dropped ws_dropped ws_slow_disconnects input_overflow history_bytes fanout_bytes"
