#!/usr/bin/env bash
#
# report.sh — turn an nginx/Apache access log into a Markdown traffic report.
#
# Assumes the "combined" log format (nginx default, Apache's combined):
#   $1 client IP   ... $4 [date ... $6 "METHOD $7 path ... $9 status $10 bytes
#
set -euo pipefail

VERSION="1.0.0"
PROG="$(basename "$0")"

LOG="/var/log/nginx/access.log"
URL=""
OUT_DIR="./reports"
TOP=5
INCLUDE_ROTATED=0
HEALTH_ONLY=0

usage() {
    cat <<EOF
$PROG $VERSION — build a Markdown traffic report from an access log.

Usage:
  $PROG [options]

Options:
  -l, --log PATH        access log to read (default: $LOG)
                        use "-" to read from stdin
  -u, --url URL         health-check this URL before reporting
  -o, --out-dir DIR     where to write the report (default: $OUT_DIR)
  -n, --top N           rows per section (default: $TOP)
      --include-rotated read PATH.1 and PATH.*.gz as well
      --health-only     only run the health check, then exit
  -h, --help            show this help
  -V, --version         print the version

Examples:
  $PROG
  $PROG --log /var/log/apache2/access.log --url https://example.com
  $PROG --log sample/access.log --out-dir /tmp/report
  $PROG --health-only --url http://localhost:3000
  zcat access.log.*.gz | $PROG --log -

Assumes the combined log format. If your log uses a custom format,
adjust the field numbers in the awk calls (IP=\$1, path=\$7, status=\$9).
EOF
}

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

need_value() { [ "$#" -ge 2 ] || die "$1 needs a value"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        -l|--log)          need_value "$@"; LOG="$2";       shift 2 ;;
        -u|--url)          need_value "$@"; URL="$2";       shift 2 ;;
        -o|--out-dir)      need_value "$@"; OUT_DIR="$2";   shift 2 ;;
        -n|--top)          need_value "$@"; TOP="$2";       shift 2 ;;
        --include-rotated) INCLUDE_ROTATED=1;               shift ;;
        --health-only)     HEALTH_ONLY=1;                   shift ;;
        -h|--help)         usage; exit 0 ;;
        -V|--version)      printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
        --)                shift; break ;;
        -*)                die "unknown option: $1 (try --help)" ;;
        *)                 die "unexpected argument: $1" ;;
    esac
done

case "$TOP" in
    ''|*[!0-9]*) die "--top must be a positive integer" ;;
esac
[ "$TOP" -gt 0 ] || die "--top must be a positive integer"

check_url() {
    [ -n "$URL" ] || return 0
    command -v curl >/dev/null 2>&1 || die "curl not found (needed for --url)"
    if curl -sf -o /dev/null --max-time 10 -- "$URL"; then
        printf 'health: %s is up\n' "$URL"
    else
        die "health check failed: $URL"
    fi
}

if [ "$HEALTH_ONLY" -eq 1 ]; then
    [ -n "$URL" ] || die "--health-only requires --url"
    check_url
    exit 0
fi

check_url

[ "$LOG" = "-" ] || [ -r "$LOG" ] || die "cannot read log: $LOG"

WORK="$(mktemp)"
trap 'rm -f "$WORK"' EXIT

read_logs() {
    local f
    if [ "$INCLUDE_ROTATED" -eq 1 ]; then
        [ "$LOG" != "-" ] || die "--include-rotated cannot be used with stdin"
        command -v gzip >/dev/null 2>&1 || die "gzip not found (needed for rotated .gz files)"
        shopt -s nullglob
        for f in "$LOG" "$LOG".1 "$LOG".*.gz; do
            [ -r "$f" ] || continue
            case "$f" in
                *.gz) gzip -dc -- "$f" ;;
                *)    cat -- "$f" ;;
            esac
        done
        shopt -u nullglob
    elif [ "$LOG" = "-" ]; then
        cat
    else
        cat -- "$LOG"
    fi
}

read_logs > "$WORK"

total=$(wc -l < "$WORK" | tr -d '[:space:]')
errors4=$(awk '$9 ~ /^4/' "$WORK" | wc -l | tr -d '[:space:]')
errors5=$(awk '$9 ~ /^5/' "$WORK" | wc -l | tr -d '[:space:]')
malformed=$(awk 'NF < 9' "$WORK" | wc -l | tr -d '[:space:]')
rate=$(awk -v e="$errors5" -v t="$total" 'BEGIN { printf "%.2f", (t ? 100 * e / t : 0) }')
served=$(awk '{ s += $10 } END { printf "%.1f", s / 1048576 }' "$WORK")

count_top() {
    sort | uniq -c | sort -rn | awk -v n="$TOP" 'NR <= n'
}

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/report_$(date +%F).md"

{
    printf '# Traffic report — %s\n\n' "$(date +%F)"
    printf 'Source: `%s` · %s requests · %s MB served' "$LOG" "$total" "$served"
    if [ -n "$URL" ]; then
        printf ' · health: up'
    fi
    printf '\n\n'

    printf '## Summary\n\n'
    printf '| metric | value |\n|---|---:|\n'
    printf '| requests | %s |\n' "$total"
    printf '| 4xx | %s |\n' "$errors4"
    printf '| 5xx | %s |\n' "$errors5"
    printf '| 5xx rate | %s%% |\n' "$rate"

    printf '\n## Top %s IPs by 5xx\n\n~~~\n' "$TOP"
    awk '$9 ~ /^5/ { print $1 }' "$WORK" | count_top
    printf '~~~\n'

    printf '\n## Top %s paths\n\n~~~\n' "$TOP"
    awk '{ print $7 }' "$WORK" | count_top
    printf '~~~\n'

    printf '\n## Status codes\n\n~~~\n'
    awk '{ print $9 }' "$WORK" | sort | uniq -c | sort -rn
    printf '~~~\n'

    if [ "$malformed" -gt 0 ]; then
        printf '\n> Warning: %s lines did not look like combined-format entries.\n' "$malformed"
    fi

    printf '\n---\nGenerated by %s %s\n' "$PROG" "$VERSION"
} > "$OUT"

printf 'wrote %s\n' "$OUT"
