#!/bin/bash
# Standalone bash harness (NO framework) exercising the REAL ERR trap / fail() /
# hc_ping() in the worktree cron.sh. Proves the trap message is BOTH
# self-explanatory (names the failing command) AND secret-free (never contains a
# secret VALUE). Each case runs against a sandboxed copy of cron.sh in its own
# mktemp dir. It NEVER touches /opt/proxyscrape or the production healthchecks.

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
WORKTREE_ROOT=$(cd "$SELF_DIR/.." && pwd)
CRON_SRC="$WORKTREE_ROOT/cron.sh"
overall=0

# Common sandbox setup shared by both cases. $1 = temp dir (already created).
setup_common() {
    local T="$1"
    mkdir -p "$T/node" "$T/bin"
    cp "$CRON_SRC" "$T/cron_test.sh"
    # Repoint SCRIPT_DIR at the sandbox so nothing reaches /opt/proxyscrape.
    sed -i "s|^SCRIPT_DIR=\"/opt/proxyscrape\"$|SCRIPT_DIR=\"$T\"|" "$T/cron_test.sh"
    if ! grep -qF "SCRIPT_DIR=\"$T\"" "$T/cron_test.sh" || grep -qE '^SCRIPT_DIR="/opt/proxyscrape"' "$T/cron_test.sh"; then
        echo "FATAL: SCRIPT_DIR repoint failed; refusing to run to avoid touching production"
        rm -rf "$T"
        exit 1
    fi
    # Secrets/config the script sources. PING_URL uses a distinct recognizable token.
    printf 'YYDS_API_KEY=dummy\nPING_URL=TESTTOKEN_ABC123\n' > "$T/.env"
    # curl stub: capture ONLY the POST body (stdin) — the ping URL legitimately
    # equals the token, so only the --data-binary body becomes the alert email.
    cat > "$T/bin/curl" <<EOF
#!/bin/bash
cat >> "$T/ping_capture.txt"
exit 0
EOF
    chmod +x "$T/bin/curl"
}

# CASE (a): a real VAR=\$(pipeline) failure (line 55 RESIN_ADMIN_TOKEN) before
# RUN_LOG exists. Proves the trap body names the full failing command.
case_a() {
    local T
    T=$(mktemp -d)
    setup_common "$T"
    # sudo = passthrough; docker inspect = exit 1 so the pipeline fails under pipefail.
    cat > "$T/bin/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF
    cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
[ "$1" = inspect ] && exit 1
exit 0
EOF
    chmod +x "$T/bin/sudo" "$T/bin/docker"
    PATH="$T/bin:$PATH" bash "$T/cron_test.sh" >/dev/null 2>&1
    local body=""
    [ -f "$T/ping_capture.txt" ] && body=$(cat "$T/ping_capture.txt")
    local ok=1
    grep -qF 'aborted at line' "$T/ping_capture.txt" 2>/dev/null || ok=0
    grep -qF 'RESIN_ADMIN_TOKEN=$(sudo docker inspect' "$T/ping_capture.txt" 2>/dev/null || ok=0
    if [ "$ok" = 1 ]; then
        echo "PASS case(a) line54_fail: trap body contains 'aborted at line' AND names the failing command 'RESIN_ADMIN_TOKEN=\$(sudo docker inspect'"
    else
        echo "FAIL case(a) line54_fail: expected body to contain 'aborted at line' AND 'RESIN_ADMIN_TOKEN=\$(sudo docker inspect'"
        echo "---- captured body (case a) ----"
        printf '%s\n' "$body"
        echo "--------------------------------"
        overall=1
    fi
    rm -rf "$T"
}

# CASE (b): a failing command referencing a secret variable. Proves BASH_COMMAND
# holds the PRE-expansion source text (\${PING_URL}), so the body is
# self-explanatory yet never leaks the secret VALUE (TESTTOKEN_ABC123).
case_b() {
    local T
    T=$(mktemp -d)
    setup_common "$T"
    # Inject a failing command that references a secret var IMMEDIATELY AFTER the
    # .env sourcing block (after `set +a`), before the RESIN_ADMIN_TOKEN line, so
    # it fires the ERR trap while PING_URL is set. No docker stub: this line fails first.
    awk '{print} /^set \+a$/{print "false \"reach ${PING_URL}\""}' "$T/cron_test.sh" > "$T/cron_test.sh.tmp"
    mv "$T/cron_test.sh.tmp" "$T/cron_test.sh"
    PATH="$T/bin:$PATH" bash "$T/cron_test.sh" >/dev/null 2>&1
    local body=""
    [ -f "$T/ping_capture.txt" ] && body=$(cat "$T/ping_capture.txt")
    local ok=1
    grep -qF '${PING_URL}' "$T/ping_capture.txt" 2>/dev/null || ok=0
    if grep -qF 'TESTTOKEN_ABC123' "$T/ping_capture.txt" 2>/dev/null; then ok=0; fi
    if [ "$ok" = 1 ]; then
        echo "PASS case(b) secret_var: trap body shows source '\${PING_URL}' AND never leaks the secret value 'TESTTOKEN_ABC123'"
    else
        echo "FAIL case(b) secret_var: expected literal '\${PING_URL}' present AND 'TESTTOKEN_ABC123' absent"
        echo "---- captured body (case b) ----"
        printf '%s\n' "$body"
        echo "--------------------------------"
        overall=1
    fi
    rm -rf "$T"
}

case_a
case_b

if [ "$overall" = 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "SOME FAILED"
exit 1
