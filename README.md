# server-log-report

Turn an nginx or Apache access log into a small Markdown traffic report — no
dependencies beyond the standard Unix tools.

```
| metric    | value  |
|-----------|-------:|
| requests  | 2000   |
| 4xx       | 429    |
| 5xx       | 495    |
| 5xx rate  | 24.75% |
```

Plus top IPs causing server errors, the most requested paths, a status-code
breakdown, and an optional uptime check.

## Why

Every server writes a log. Almost nobody reads it. This script does the boring
part: it reads yesterday's traffic and writes the five things you actually want
to know, in a file you can diff week over week.

It is deliberately small and hackable. Read it, change it, keep it in your own
dotfiles.

## Requirements

- `bash` (3.2+, so it works on macOS too)
- `awk`, `sort`, `uniq`, `wc`, `mktemp` — on every Unix
- `curl` — only if you use `--url`
- `gzip` — only if you use `--include-rotated`

## Quick start

```bash
git clone https://github.com/gideonadeti/server-log-report.git
cd server-log-report

./report.sh --log /var/log/nginx/access.log --out-dir ./reports
cat reports/report_*.md
```

Try it without touching a real server:

```bash
./sample/generate-log.sh 500 > /tmp/access.log
./report.sh --log /tmp/access.log --out-dir /tmp/report
cat /tmp/report/report_*.md
```

## Usage

```
report.sh [options]

  -l, --log PATH        access log to read (default: /var/log/nginx/access.log)
                        use "-" to read from stdin
  -u, --url URL         health-check this URL before reporting
  -o, --out-dir DIR     where to write the report (default: ./reports)
  -n, --top N           rows per section (default: 5)
      --include-rotated read PATH.1 and PATH.*.gz as well
      --health-only     only run the health check, then exit
  -h, --help            show the help
  -V, --version         print the version
```

Examples:

```bash
# nginx, with an uptime check
./report.sh -l /var/log/nginx/access.log -u https://example.com

# Apache
./report.sh -l /var/log/apache2/access.log

# include rotated logs (a whole week, not just today)
./report.sh -l /var/log/nginx/access.log --include-rotated

# already-decompressed logs from stdin
zcat /var/log/nginx/access.log.*.gz | ./report.sh --log -

# just check that a site is up
./report.sh --health-only --url https://example.com
```

## Running it locally (e.g. `localhost:3000`)

Yes — the health check works against anything curl can reach:

```bash
# while your dev server is running
./report.sh --health-only --url http://localhost:3000
```

```
health: http://localhost:3000 is up
```

The **report** part needs an access log, and a dev server usually doesn't write
one. Three options:

1. Use the bundled sample log to exercise the report:
   ```bash
   ./report.sh --log sample/access.log --out-dir /tmp/report
   ```
2. Log requests from a tiny local server and point the script at it:
   ```bash
   python3 -m http.server 8000 2> /tmp/access.log
   ./report.sh --log /tmp/access.log --out-dir /tmp/report
   ```
   (Python's log lines are not in combined format, so this is for the uptime
   check, not the parsing. Use nginx if you want realistic data.)
3. Put nginx in front of your app locally and read its `access.log`.

## Log format

The script assumes the **combined** format, which is nginx's default and one of
Apache's defaults:

```
$1 client IP  $2 ident  $3 user  $4 [date  $5 tz]  $6 "METHOD  $7 path  $8 proto"  $9 status  $10 bytes  $11 referrer  $12 user-agent
```

Check before trusting it:

```bash
sudo awk '{print NF}' /var/log/nginx/access.log | sort -u   # should be consistent
sudo awk '{print $9}' /var/log/nginx/access.log | sort -u    # should be status codes
```

If your server uses a custom `log_format`, change `$1`, `$7` and `$9` in
`report.sh`. If your logs are JSON, this script is the wrong tool — use `jq`.

## Permissions

`/var/log/nginx/` is usually readable only by root. Prefer one of these over
running the whole report as root:

```bash
# Debian/Ubuntu: add yourself to the adm group, then log out and back in
sudo usermod -aG adm "$USER"

# or grant a read ACL on the file
sudo setfacl -m "u:$USER:r" /var/log/nginx/access.log

# or run it with sudo (fine for a one-off)
sudo ./report.sh --log /var/log/nginx/access.log
```

## Log rotation

`access.log` only contains the current period. If logrotate is enabled,
older data lives in `access.log.1` and `access.log.*.gz`. Use
`--include-rotated` to read the current file, yesterday's, and the compressed
archives in one pass.

For a genuinely weekly report, either run this daily and keep the files, or
aggregate the rotated set. Keep an eye on disk usage: logs grow fast, and
compressing them is cheaper than storing them raw.

## Scheduling

cron:

```cron
0 8 * * 1 cd /opt/server-log-report && ./report.sh \
  --log /var/log/nginx/access.log --url https://example.com \
  --out-dir /var/reports >> /var/log/server-report.log 2>&1
```

Note that cron starts with a minimal `PATH`, so use absolute paths or set
`PATH` inside the crontab.

systemd timer (nicer logs and failure handling):

```ini
# ~/.config/systemd/user/server-report.service
[Unit]
Description=Weekly server log report

[Service]
Type=oneshot
WorkingDirectory=%h/opt/server-log-report
ExecStart=%h/opt/server-log-report/report.sh --log /var/log/nginx/access.log --out-dir %h/reports
```

```ini
# ~/.config/systemd/user/server-report.timer
[Unit]
Description=Run the server report every Monday

[Timer]
OnCalendar=Mon 08:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user enable --now server-report.timer
```

## Notes and limitations

- **IPs are personal data.** If you publish or share reports, consider hashing
  or removing them (GDPR-minded readers will thank you).
- **Behind a proxy/CDN** (Cloudflare, a load balancer), the logged IP is the
  proxy's, not the visitor's. Configure `real_ip` in nginx or read
  `X-Forwarded-For` if that matters.
- **Custom log formats** need field changes. The script warns if lines don't
  have at least 9 fields, but it cannot know your format.
- **This is a summary, not analytics.** It answers "is anything on fire?"
  For funnels, retention, and dashboards, use a real analytics product.

## License

MIT — see [LICENSE](LICENSE).
