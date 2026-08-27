#!/bin/bash
# Standalone harness for the real MIN_PROXIES yield gate in cron.sh.
# No test framework: for each N in 299 300 301 it sandboxes a copy of the real
# cron.sh, stubs every external command, runs the actual gate, and asserts the
# outcome. Nothing ever touches /opt/proxyscrape, the production healthchecks,
# or any real LAST_RUN_STATUS/cron.log — all state lives under a per-N mktemp dir.

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
WORKTREE_ROOT=$(cd "$SELF_DIR/.." && pwd)
CRON_SH="$WORKTREE_ROOT/cron.sh"

overall_fail=0

fail_case() {
    # $1 = N, remaining args = message
    local n="$1"
    shift
    echo "[N=$n] FAIL: $*"
    overall_fail=1
}

run_case() {
    local N="$1"
    echo "[N=$N] running real yield gate..."
    local T
    T=$(mktemp -d)
    mkdir -p "$T/node" "$T/bin"

    # Step 2: sandbox copy of the real cron.sh.
    cp "$CRON_SH" "$T/cron_test.sh"

    # Step 3: repoint SCRIPT_DIR at the sandbox instead of /opt/proxyscrape.
    sed -i "s|^SCRIPT_DIR=\"/opt/proxyscrape\"$|SCRIPT_DIR=\"$T\"|" "$T/cron_test.sh"

    # Step 4: truncate everything past the gate's success log line.
    awk '{print} /Registered batch:/{print "exit 0"}' "$T/cron_test.sh" > "$T/cron_test.sh.new"
    mv "$T/cron_test.sh.new" "$T/cron_test.sh"

    # Safety: never run unless SCRIPT_DIR was actually repointed away from production.
    if ! grep -qF "SCRIPT_DIR=\"$T\"" "$T/cron_test.sh" || grep -qE '^SCRIPT_DIR="/opt/proxyscrape"' "$T/cron_test.sh"; then
        fail_case "$N" "SCRIPT_DIR repoint failed; refusing to run to avoid touching production"
        rm -rf "$T"
        return
    fi
    if ! grep -qxF "exit 0" "$T/cron_test.sh"; then
        fail_case "$N" "exit 0 truncation not inserted after 'Registered batch:'; refusing to run"
        rm -rf "$T"
        return
    fi

    # Step 5: stub every external command under $T/bin.
    cat > "$T/bin/sudo" <<'STUB'
#!/bin/bash
# Passthrough: run whatever sudo was asked to run (which is another stub here).
exec "$@"
STUB
    cat > "$T/bin/docker" <<'STUB'
#!/bin/bash
# Make the pre-gate RESIN_ADMIN_TOKEN read succeed so execution reaches the gate;
# no-op for anything that is not an inspect.
for a in "$@"; do
    if [ "$a" = "inspect" ]; then
        echo "RESIN_ADMIN_TOKEN=faketoken"
        exit 0
    fi
done
exit 0
STUB
    cat > "$T/bin/xvfb-run" <<'STUB'
#!/bin/bash
# Ignore all args (the real xvfb-run + python register). Consume the heredoc on
# stdin, emit a passing "完成 X/N" accounts line (tee'd into RUN_LOG so the
# accounts gate passes), and write a batch file of N proxies into the node dir.
cat >/dev/null
yes 'user:pass@1.2.3.4:8080' | head -n "$HARNESS_N" > "$HARNESS_NODE_DIR/proxies_$(date +%Y%m%d)_test.txt"
echo "  完成 5/5"
STUB
    cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
# Capture the URL (last arg) and the POST body instead of letting any ping leave
# the machine.
body=$(cat)
url=""
for u in "$@"; do url="$u"; done
{ printf '%s\n' "$url"; printf '%s\n' "$body"; } >> "$HARNESS_CAPTURE"
exit 0
STUB
    chmod +x "$T/bin"/*

    # Step 6: sandbox .env (dummy secrets, an unreachable ping URL).
    printf 'YYDS_API_KEY=dummy\nPING_URL=http://127.0.0.1:0/dummy\n' > "$T/.env"

    # Step 7: run the real gate fully sandboxed.
    local rc
    PATH="$T/bin:$PATH" \
        HARNESS_N="$N" \
        HARNESS_NODE_DIR="$T/node" \
        HARNESS_CAPTURE="$T/ping_capture.txt" \
        bash "$T/cron_test.sh" > "$T/run_stdout.txt" 2>&1
    rc=$?

    local status_content log_content capture_content batch_path
    status_content=$(cat "$T/LAST_RUN_STATUS" 2>/dev/null || true)
    log_content=$(cat "$T/cron.log" 2>/dev/null || true)
    capture_content=$(cat "$T/ping_capture.txt" 2>/dev/null || true)
    batch_path=$(ls "$T"/node/proxies_*_test.txt 2>/dev/null | head -1)

    local case_ok=1
    if [ "$N" -eq 299 ]; then
        local phrase="yielded only 299 proxies (need >= 300)"
        if [ "$rc" -ne 1 ]; then
            fail_case "$N" "expected exit code 1, got $rc"
            case_ok=0
        fi
        if ! printf '%s' "$status_content" | grep -qF -- "$phrase"; then
            fail_case "$N" "LAST_RUN_STATUS missing phrase [$phrase]; got: [$status_content]"
            case_ok=0
        fi
        if ! printf '%s' "$capture_content" | grep -qF -- "$phrase"; then
            fail_case "$N" "/fail ping body missing phrase [$phrase]; capture: [$capture_content]"
            case_ok=0
        fi
        if ! printf '%s' "$capture_content" | grep -qF -- "$batch_path"; then
            fail_case "$N" "/fail ping body missing batch-file path [$batch_path]; capture: [$capture_content]"
            case_ok=0
        fi
    else
        # N=300 and N=301: the gate must pass and truncate.
        if ! printf '%s' "$log_content" | grep -qF -- "Registered batch:"; then
            fail_case "$N" "cron.log missing 'Registered batch:'; log: [$log_content]"
            case_ok=0
        fi
        if ! printf '%s' "$log_content" | grep -qF -- "($N proxies)"; then
            fail_case "$N" "cron.log missing '($N proxies)'; log: [$log_content]"
            case_ok=0
        fi
        if printf '%s' "$status_content$log_content$capture_content" | grep -qF -- "yielded only"; then
            fail_case "$N" "unexpected 'yielded only' in status/log/capture on a passing run"
            case_ok=0
        fi
    fi

    if [ "$case_ok" -eq 1 ]; then
        echo "[N=$N] PASS (rc=$rc)"
    fi

    # Clean up this iteration's sandbox.
    rm -rf "$T"
}

echo "=== yield gate harness (cron.sh MIN_PROXIES) ==="
echo "cron.sh under test: $CRON_SH"
for N in 299 300 301; do
    run_case "$N"
done

if [ "$overall_fail" -ne 0 ]; then
    echo "=== RESULT: FAIL ==="
    exit 1
fi
echo "=== RESULT: all cases passed ==="
exit 0
