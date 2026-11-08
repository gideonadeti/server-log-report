#!/usr/bin/env bash
#
# report.sh — turn an nginx/Apache access log into a Markdown or JSON report.
#
# Field positions depend on the log format. The three built-in formats cover the
# common cases; --fields is the escape hatch for anything custom.
#
set -euo pipefail

VERSION="1.1.0"
PROG="$(basename "$0")"

LOG="/var/log/nginx/access.log"
URL=""
OUT_DIR="./reports"
TOP=5
INCLUDE_ROTATED=0
HEALTH_ONLY=0
JSON_OUT=0

FORMAT="combined"
IP_FIELD=1
PATH_FIELD=7
STATUS_FIELD=9
BYTES_FIELD=10
FIELDS_OVERRIDE=""

usage() {
    cat <<EOF
$PROG $VERSION — build a traffic report from an access log.

Usage:
  $PROG [options]

Options:
  -l, --log PATH        access log to read (default: $LOG)
                        use "-" to read from stdin
  -u, --url URL         health-check this URL before reporting
  -o, --out-dir DIR     where to write the report (default: $OUT_DIR)
  -n, --top N           rows per section (default: $TOP)
  -f, --format NAME     input log format: combined (default), common,
                        vhost_combined
      --fields F,F,F,F  custom field numbers: IP,PATH,STATUS,BYTES
                        (overrides --format)
      --json            print a JSON report to stdout instead of Markdown
      --include-rotated read PATH.1 and PATH.*.gz as well
      --health-only     only run the health check, then exit
  -h, --help            show this help
  -V, --version         print the version

Formats:
  combined        \$1 IP  \$7 path  \$9 status  \$10 bytes   (nginx default,
                  Apache "combined")
  common          same positions; the only difference is the missing
                  referrer/user-agent tail, which this script ignores
  vhost_combined  \$2 IP  \$8 path  \$10 status \$11 bytes   (Apache vhost logs)

Examples:
  $PROG
  $PROG --log /var/log/apache2/access.log --format vhost_combined
  $PROG --log /var/log/nginx/access.log --url https://example.com --json | jq .
  $PROG --log sample/access.log --fields 2,8,10,11
  $PROG --health-only --url http://localhost:3000
  zcat access.log.*.gz | $PROG --log -
EOF
}

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

need_value() { [ "$#" -ge 2 ] || die "$1 needs a value"; }

valid_field() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -gt 0 ]
}

set_format() {
    case "$1" in
        combined|nginx|apache_combined)
            IP_FIELD=1; PATH_FIELD=7; STATUS_FIELD=9; BYTES_FIELD=10 ;;
        common|apache_common)
            IP_FIELD=1; PATH_FIELD=7; STATUS_FIELD=9; BYTES_FIELD=10 ;;
        vhost_combined|apache_vhost)
            IP_FIELD=2; PATH_FIELD=8; STATUS_FIELD=10; BYTES_FIELD=11 ;;
        *)
            die "unknown format: $1 (try combined, common, vhost_combined, or --fields)" ;;
    esac
}

parse_fields() {
    local a b c d
    IFS=',' read -r a b c d <<< "$1"
    valid_field "$a" && valid_field "$b" && valid_field "$c" && valid_field "$d" \
        || die "--fields expects four positive numbers: IP,PATH,STATUS,BYTES"
    IP_FIELD="$a"; PATH_FIELD="$b"; STATUS_FIELD="$c"; BYTES_FIELD="$d"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -l|--log)          need_value "$@"; LOG="$2";          shift 2 ;;
        -u|--url)          need_value "$@"; URL="$2";          shift 2 ;;
        -o|--out-dir)      need_value "$@"; OUT_DIR="$2";      shift 2 ;;
        -n|--top)          need_value "$@"; TOP="$2";          shift 2 ;;
        -f|--format)       need_value "$@"; FORMAT="$2";       shift 2 ;;
        --fields)          need_value "$@"; FIELDS_OVERRIDE="$2"; shift 2 ;;
        --json)            JSON_OUT=1;                         shift ;;
        --include-rotated) INCLUDE_ROTATED=1;                  shift ;;
        --health-only)     HEALTH_ONLY=1;                      shift ;;
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

set_format "$FORMAT"
if [ -n "$FIELDS_OVERRIDE" ]; then
    parse_fields "$FIELDS_OVERRIDE"
    FORMAT="custom($FIELDS_OVERRIDE)"
fi

if [ "$JSON_OUT" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || die "jq not found (needed for --json)"
fi

MIN_FIELDS="$IP_FIELD"
if [ "$PATH_FIELD" -gt "$MIN_FIELDS" ]; then MIN_FIELDS="$PATH_FIELD"; fi
if [ "$STATUS_FIELD" -gt "$MIN_FIELDS" ]; then MIN_FIELDS="$STATUS_FIELD"; fi
if [ "$BYTES_FIELD" -gt "$MIN_FIELDS" ]; then MIN_FIELDS="$BYTES_FIELD"; fi

HEALTH_STATUS=""
check_url() {
    [ -n "$URL" ] || return 0
    command -v curl >/dev/null 2>&1 || die "curl not found (needed for --url)"
    if curl -sf -o /dev/null --max-time 10 -- "$URL"; then
        HEALTH_STATUS="up"
        if [ "$JSON_OUT" -eq 0 ]; then
            printf 'health: %s is up\n' "$URL"
        fi
    else
        die "health check failed: $URL"
    fi
}

if [ "$HEALTH_ONLY" -eq 1 ]; then
    [ -n "$URL" ] || die "--health-only requires --url"
    check_url
    if [ "$JSON_OUT" -eq 1 ]; then
        jq -n --arg url "$URL" '{url: $url, up: true}'
    fi
    exit 0
fi

check_url

[ "$LOG" = "-" ] || [ -r "$LOG" ] || die "cannot read log: $LOG"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
WORK="$WORKDIR/log"

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
errors4=$(awk -v f="$STATUS_FIELD" '$f ~ /^4/' "$WORK" | wc -l | tr -d '[:space:]')
errors5=$(awk -v f="$STATUS_FIELD" '$f ~ /^5/' "$WORK" | wc -l | tr -d '[:space:]')
malformed=$(awk -v m="$MIN_FIELDS" 'NF < m' "$WORK" | wc -l | tr -d '[:space:]')
rate=$(awk -v e="$errors5" -v t="$total" 'BEGIN { printf "%.2f", (t ? 100 * e / t : 0) }')
bytes=$(awk -v f="$BYTES_FIELD" '{ s += $f } END { printf "%.0f", s }' "$WORK")
served=$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1048576 }')

# Turn "  12 value" lines (uniq -c) into "12<TAB>value", preserving the value.
to_tsv() {
    awk '{
        line = $0
        sub(/^[[:space:]]+/, "", line)
        count = line
        sub(/[[:space:]].*/, "", count)
        value = line
        sub(/^[^[:space:]]+[[:space:]]+/, "", value)
        printf "%s\t%s\n", count, value
    }'
}

count_top_tsv() {
    sort | uniq -c | sort -rn | awk -v n="$TOP" 'NR <= n' | to_tsv
}

count_all_tsv() {
    sort | uniq -c | sort -rn | to_tsv
}

awk -v ip="$IP_FIELD" -v st="$STATUS_FIELD" '$st ~ /^5/ { print $ip }' "$WORK" \
    | count_top_tsv > "$WORKDIR/ips.tsv"
awk -v p="$PATH_FIELD" '{ print $p }' "$WORK" \
    | count_top_tsv > "$WORKDIR/paths.tsv"
awk -v st="$STATUS_FIELD" '{ print $st }' "$WORK" \
    | count_all_tsv > "$WORKDIR/status.tsv"

if [ "$JSON_OUT" -eq 1 ]; then
    health_json="null"
    if [ -n "$URL" ]; then
        health_json=$(jq -n --arg url "$URL" '{url: $url, up: true}')
    fi

    ips_json=$(jq -R -s '
        split("\n") | map(select(length > 0) | split("\t") |
        {ip: .[1], count: (.[0] | tonumber)})' < "$WORKDIR/ips.tsv")
    paths_json=$(jq -R -s '
        split("\n") | map(select(length > 0) | split("\t") |
        {path: .[1], count: (.[0] | tonumber)})' < "$WORKDIR/paths.tsv")
    status_json=$(jq -R -s '
        split("\n") | map(select(length > 0) | split("\t") |
        {status: (.[1] | tonumber), count: (.[0] | tonumber)})' < "$WORKDIR/status.tsv")

    summary_json=$(jq -n \
        --argjson requests "$total" \
        --argjson status_4xx "$errors4" \
        --argjson status_5xx "$errors5" \
        --argjson error_rate_pct "$rate" \
        --argjson bytes_served "$bytes" \
        '{requests: $requests, status_4xx: $status_4xx, status_5xx: $status_5xx,
          error_rate_pct: $error_rate_pct, bytes_served: $bytes_served}')

    jq -n \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg source "$LOG" \
        --arg format "$FORMAT" \
        --argjson health "$health_json" \
        --argjson summary "$summary_json" \
        --argjson top_ips_by_5xx "$ips_json" \
        --argjson top_paths "$paths_json" \
        --argjson status_codes "$status_json" \
        --argjson malformed_lines "$malformed" \
        '{generated_at: $generated_at, source: $source, format: $format,
          health: $health, summary: $summary, top_ips_by_5xx: $top_ips_by_5xx,
          top_paths: $top_paths, status_codes: $status_codes,
          malformed_lines: $malformed_lines}'
    exit 0
fi

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/report_$(date +%F).md"

print_tsv() {
    awk -F'\t' '{ printf "%6s  %s\n", $1, $2 }' "$1"
}

{
    printf '# Traffic report — %s\n\n' "$(date +%F)"
    printf 'Source: `%s` · format: %s · %s requests · %s MB served' \
        "$LOG" "$FORMAT" "$total" "$served"
    if [ -n "$HEALTH_STATUS" ]; then
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
    print_tsv "$WORKDIR/ips.tsv"
    printf '~~~\n'

    printf '\n## Top %s paths\n\n~~~\n' "$TOP"
    print_tsv "$WORKDIR/paths.tsv"
    printf '~~~\n'

    printf '\n## Status codes\n\n~~~\n'
    print_tsv "$WORKDIR/status.tsv"
    printf '~~~\n'

    if [ "$malformed" -gt 0 ]; then
        printf '\n> Warning: %s lines did not look like %s entries.\n' \
            "$malformed" "$FORMAT"
    fi

    printf '\n---\nGenerated by %s %s\n' "$PROG" "$VERSION"
} > "$OUT"

printf 'wrote %s\n' "$OUT"
