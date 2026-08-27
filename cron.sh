#!/bin/bash
set -euo pipefail

SCRIPT_DIR="/opt/proxyscrape"
TURNSTILE_EXTENSION_PATH="$SCRIPT_DIR/turnstilePatch"
RESIN_API="http://127.0.0.1:2260/api/v1"
RETENTION_DAYS=8
COUNT=5
THREADS=1
MIN_ACCOUNTS=3                       # X < this on the "完成 X/N" line = failure
MIN_PROXIES=300                      # batch proxy yield below this = failure (3 accounts x 100)
HC_BODY_LIMIT=9000                   # cap ping body under healthchecks' 10000-byte PING_BODY_LIMIT
LOG_FILE="$SCRIPT_DIR/cron.log"
STATUS_FILE="$SCRIPT_DIR/LAST_RUN_STATUS"
NODE_DIR="$SCRIPT_DIR/node"
ARCHIVE_DIR="$NODE_DIR/archive"
RUN_LOG=""                           # per-run output capture; set just before the run

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Ping healthchecks. $1 = url suffix (""=success, "/fail"=failure). $2 = reason line.
# Never affects the script's own outcome: no PING_URL -> no-op; a failed ping is logged, not fatal.
hc_ping() {
    [ -n "${PING_URL:-}" ] || return 0
    {
        if [ -n "${2:-}" ]; then printf '%s\n\n' "$2"; fi
        if [ -n "${RUN_LOG:-}" ] && [ -s "$RUN_LOG" ]; then
            tail -n 50 "$RUN_LOG" | tail -c "$HC_BODY_LIMIT"
        fi
    } | curl -fsS -m 10 --data-binary @- -o /dev/null "${PING_URL}${1:-}" 2>>"$LOG_FILE" \
        || log "[WARN] healthchecks ping failed (suffix='${1:-}')"
    return 0
}

fail() {
    log "[ALERT] $*"
    echo "FAILED $(date '+%Y-%m-%d %H:%M:%S') :: $*" > "$STATUS_FILE"
    hc_ping "/fail" "$*"
    exit 1
}
# Any unhandled command failure lands here instead of exiting silently.
trap 'fail "aborted at line $LINENO: $BASH_COMMAND"' ERR
# Remove per-run temp files on ANY exit; runs after fail()'s hc_ping has read RUN_LOG.
trap 'rm -f "${RUN_LOG:-}" "${POOL_FILE:-}"' EXIT

# Secrets/config kept out of the repo: YYDS_API_KEY (temp-mail) and PING_URL
# (healthchecks capability token). set -a so sourced vars are exported to python.
set -a
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"
set +a
[ -n "${YYDS_API_KEY:-}" ] || fail "YYDS_API_KEY not set - expected in $SCRIPT_DIR/.env"

# The admin token is read from the resin container env instead of being hardcoded
# here in plaintext (changed 2026-08-13).
RESIN_ADMIN_TOKEN=$(sudo docker inspect resin --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^RESIN_ADMIN_TOKEN=' | cut -d= -f2-)
[ -n "$RESIN_ADMIN_TOKEN" ] || fail "could not read RESIN_ADMIN_TOKEN from the resin container env"

log "=== Starting ProxyScrape registration (count=$COUNT, threads=$THREADS, retention=${RETENTION_DAYS}d) ==="

export YYDS_API_KEY TURNSTILE_EXTENSION_PATH

RUN_LOG=$(mktemp /tmp/ps_run_XXXXXX.log)
xvfb-run --auto-servernum --server-args="-screen 0 1280x900x24" \
  python3 "$SCRIPT_DIR/proxyscrape_register.py" <<EOF 2>&1 | tee -a "$LOG_FILE" > "$RUN_LOG"
$COUNT
$THREADS
Y
0
EOF

# Registration success gate: parse the "完成 X/N" summary the python prints.
# grep guarded with || true so a no-match cannot trip set -e / the ERR trap.
DONE_LINE=$(grep -oE '完成 [0-9]+/[0-9]+' "$RUN_LOG" | tail -1 || true)
COMPLETED=""
if [ -n "$DONE_LINE" ]; then
    COMPLETED=${DONE_LINE##* }
    COMPLETED=${COMPLETED%%/*}
fi
if [ -z "$COMPLETED" ] || [ "$COMPLETED" -lt "$MIN_ACCOUNTS" ]; then
    fail "registration produced only ${COMPLETED:-0}/${COUNT} accounts (need >= ${MIN_ACCOUNTS})"
fi
log "Registration completed ${COMPLETED}/${COUNT} accounts"

[ -d "$NODE_DIR" ] || fail "No node directory found, registration failed"

LATEST=$(ls -t "$NODE_DIR"/proxies_*.txt 2>/dev/null | head -1)
[ -n "$LATEST" ] && [ -s "$LATEST" ] || fail "No proxy file found or empty, registration failed"
BATCH_COUNT=$(wc -l < "$LATEST")
if [ "$BATCH_COUNT" -lt "$MIN_PROXIES" ]; then
    fail "registration batch $LATEST yielded only $BATCH_COUNT proxies (need >= $MIN_PROXIES)"
fi
log "Registered batch: $LATEST ($BATCH_COUNT proxies)"

# ---------------------------------------------------------------------------
# Build the pool from registration output within the retention window.
# The old script merged new proxies into the previous subscription content with
# `sort -u`, which only deduped and never expired anything: the list grew to
# 10419 lines (120 accounts, most of them dead trial credentials) and blew past
# the 128 KB single-argument limit, so the recreate curl died with
# "Argument list too long" after the delete had already succeeded.
# Rebuilding from the dated filenames keeps the pool bounded by construction.
# ---------------------------------------------------------------------------
CUTOFF=$(date -d "$RETENTION_DAYS days ago" +%Y%m%d)
POOL_FILE=$(mktemp /tmp/ps_pool_XXXXXX.txt)
: > "$POOL_FILE"
for f in "$NODE_DIR"/proxies_*.txt; do
    [ -e "$f" ] || continue
    d=$(basename "$f" | sed -E 's/proxies_([0-9]{8})_.*/\1/')
    if [ "$d" -ge "$CUTOFF" ] 2>/dev/null; then
        sed 's|^|http://|' "$f" >> "$POOL_FILE"
    fi
done
sort -u -o "$POOL_FILE" "$POOL_FILE"
POOL_COUNT=$(wc -l < "$POOL_FILE")
[ "$POOL_COUNT" -gt 0 ] || fail "Pool is empty after applying ${RETENTION_DAYS}d retention"
log "Pool built from last ${RETENTION_DAYS}d: $POOL_COUNT proxies (cutoff $CUTOFF)"

# ---------------------------------------------------------------------------
# Resin: unified-txt (since 2026-08-03). The pool is no longer pushed to resin
# via local subscriptions; resin instead polls the same txt file served by
# proxy-fileserver, via its remote subscription "proxyscrape-txt"
# (url=http://proxy-fileserver:8080/proxy_proxies.txt, refresh 5m). Creating
# subscriptions here would duplicate the pool under a second source.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Feed file for resin: same retention window. The source file is rebuilt from the
# pool rather than accumulated in place, so it cannot grow without bound either.
# resin consumes it through its remote subscription "proxyscrape-txt"
# (http://proxy-fileserver:8080/proxy_proxies.txt). It fed rota too until rota was
# deleted on 2026-08-13, so this block is now resin-only — and NOT optional:
# proxyscrape-txt supplies ~97% of resin nodes.
# ---------------------------------------------------------------------------
#
# /tmp/proxy_proxies.txt is bind-mounted read-only into proxy-fileserver at
# /www/proxy_proxies.txt, so writing the host file is all that is needed and the
# old `docker cp` could never work: replacing a bind-mounted file requires an
# unlink, which the kernel refuses with "device or resource busy". The original
# script hid that with 2>/dev/null. Truncate-in-place (`>`) keeps the inode, so
# the mount stays valid — do not replace this with a mv or a new file.
PROXY_FILE=/tmp/proxy_proxies.txt
sed -E 's|^http://([^:]+):([^@]+)@(.+)$|\3:\1:\2|' "$POOL_FILE" | sort -u > "$PROXY_FILE"
PROXY_COUNT=$(wc -l < "$PROXY_FILE")
# The redirection must run inside the container; `docker exec cmd < file` would
# have the host shell open the path instead.
SERVED=$(sudo docker exec proxy-fileserver sh -c 'wc -l < /www/proxy_proxies.txt' 2>/dev/null | tr -d ' ' || echo 0)
[ "$SERVED" = "$PROXY_COUNT" ] || fail "Feed file not visible in container: host=$PROXY_COUNT served=$SERVED"
log "Feed file rebuilt with $PROXY_COUNT proxies (verified through the bind mount)"

# ---------------------------------------------------------------------------
# Archive registration batches that fell out of the retention window. They are
# moved rather than deleted so the account records stay auditable.
# ---------------------------------------------------------------------------
mkdir -p "$ARCHIVE_DIR"
ARCHIVED=0
for f in "$NODE_DIR"/proxies_*.txt; do
    [ -e "$f" ] || continue
    d=$(basename "$f" | sed -E 's/proxies_([0-9]{8})_.*/\1/')
    if [ "$d" -lt "$CUTOFF" ] 2>/dev/null; then
        mv "$f" "$ARCHIVE_DIR/"
        ARCHIVED=$((ARCHIVED + 1))
    fi
done
log "Archived $ARCHIVED registration batches older than ${RETENTION_DAYS}d"

rm -f "$POOL_FILE"

# Clean circuit-open nodes on the unified txt subscription. The subscription
# id is looked up by name so it survives future re-creation.
TXT_SUB=$(curl -s -m 15 -H "Authorization: Bearer $RESIN_ADMIN_TOKEN" "$RESIN_API/subscriptions" | \
    python3 -c 'import sys,json;data=json.load(sys.stdin);print(next((s["id"] for s in data.get("items",[]) if s["name"]=="proxyscrape-txt"),""))' 2>/dev/null || echo "")
if [ -n "$TXT_SUB" ]; then
    CLEANED=$(curl -s -m 60 -X POST -H "Authorization: Bearer $RESIN_ADMIN_TOKEN" \
        "$RESIN_API/subscriptions/$TXT_SUB/actions/cleanup-circuit-open-nodes" | \
        python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("cleaned_count",d.get("count",0)))' 2>/dev/null || echo "?")
else
    CLEANED=0
fi
log "Resin: cleanup removed $CLEANED circuit-open nodes (subscription $TXT_SUB)"

NODE_TOTAL=$(curl -s -m 15 -H "Authorization: Bearer $RESIN_ADMIN_TOKEN" \
    "$RESIN_API/nodes?limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("total",0))' 2>/dev/null || echo 0)

echo "OK $(date '+%Y-%m-%d %H:%M:%S') :: pool=$POOL_COUNT nodes=$NODE_TOTAL feed=$PROXY_COUNT" > "$STATUS_FILE"
log "=== Done ==="
hc_ping "" "OK :: pool=$POOL_COUNT nodes=$NODE_TOTAL feed=$PROXY_COUNT"
