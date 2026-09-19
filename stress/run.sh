#!/usr/bin/env bash
# Spins up: fake ntfy endpoint -> ntfy.zig (built from source) -> locust,
# all pointed at each other, for a local stress test. Ctrl-C tears everything
# down.
set -euo pipefail
cd "$(dirname "$0")"

FAKE_NTFY_PORT="${FAKE_NTFY_PORT:-9999}"
NTFY_ZIG_PORT=8085
COOLIFY_SECRET="${COOLIFY_SECRET:-stress-coolify-secret}"
GITHUB_SECRET="${GITHUB_SECRET:-stress-github-secret}"
LOCUST_USERS="${LOCUST_USERS:-50}"
LOCUST_SPAWN_RATE="${LOCUST_SPAWN_RATE:-10}"
LOCUST_RUN_TIME="${LOCUST_RUN_TIME:-1m}"

config_file="$(mktemp)"
pids=()
cleanup() {
    rm -f "$config_file"
    for pid in "${pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

echo "== syncing uv env (python 3.14t) =="
uv sync

echo "== building ntfy.zig =="
(cd .. && zig build)

echo "== starting fake ntfy on :${FAKE_NTFY_PORT} =="
FAKE_NTFY_PORT="$FAKE_NTFY_PORT" uv run python fake_ntfy.py &
pids+=($!)

cat > "$config_file" <<EOF
{"channels": [
  {"type": "coolify", "secret": "${COOLIFY_SECRET}",
   "ntfy_url": "http://127.0.0.1:${FAKE_NTFY_PORT}/stress-coolify", "ntfy_token": "tk_stress"},
  {"type": "github", "secret": "${GITHUB_SECRET}",
   "ntfy_url": "http://127.0.0.1:${FAKE_NTFY_PORT}/stress-github", "ntfy_token": "tk_stress"}
]}
EOF

echo "== starting ntfy.zig on :${NTFY_ZIG_PORT} (health/metrics on :9090) =="
CONFIG_FILE="$config_file" \
../zig-out/bin/ntfy.zig &
pids+=($!)

echo "== waiting for ntfy.zig to become ready =="
for i in $(seq 1 50); do
    if curl -sf "http://127.0.0.1:9090/health" > /dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 50 ]; then
        echo "ntfy.zig did not become ready in time" >&2
        exit 1
    fi
    sleep 0.1
done

echo "== running locust headless: ${LOCUST_USERS} users, spawn rate ${LOCUST_SPAWN_RATE}/s, ${LOCUST_RUN_TIME} =="
COOLIFY_SECRET="$COOLIFY_SECRET" \
GITHUB_SECRET="$GITHUB_SECRET" \
uv run locust -f locustfile.py \
    --host "http://127.0.0.1:${NTFY_ZIG_PORT}" \
    --headless \
    --users "$LOCUST_USERS" \
    --spawn-rate "$LOCUST_SPAWN_RATE" \
    --run-time "$LOCUST_RUN_TIME" \
    --print-stats

echo "== fake ntfy stats =="
curl -s "http://127.0.0.1:${FAKE_NTFY_PORT}/stats"
echo
echo "== ntfy.zig /metrics =="
curl -s "http://127.0.0.1:9090/metrics"
