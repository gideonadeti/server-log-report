#!/usr/bin/env bash
# Generates a fake combined-format access log for testing.
# Usage: ./generate-log.sh [count] > access.log
set -euo pipefail

COUNT="${1:-500}"

case "$COUNT" in
    ''|*[!0-9]*) echo "usage: $0 [count]" >&2; exit 1 ;;
esac

awk -v n="$COUNT" 'BEGIN {
    srand(7)
    split("203.0.113.7 198.51.100.23 192.0.2.44 203.0.113.99 198.51.100.5", ips, " ")
    split("/ /login /api/orders /static/app.js /api/users /health", paths, " ")
    split("200 200 200 200 404 500 502 301", codes, " ")
    for (i = 0; i < n; i++) {
        printf "%s - - [08/Nov/2026:%02d:%02d:%02d +0000] \"GET %s HTTP/1.1\" %d %d\n",
            ips[int(rand() * 5) + 1],
            int(rand() * 24), int(rand() * 60), int(rand() * 60),
            paths[int(rand() * 6) + 1],
            codes[int(rand() * 8) + 1],
            int(rand() * 5000)
    }
}'
