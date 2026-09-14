# ntfy.zig stress test

Locust load test for ntfy.zig's webhook relay, plus a fake ntfy publish
endpoint to forward into — both in one `uv` environment running Python
3.14t (free-threaded), so the fake endpoint's `ThreadingHTTPServer` handles
concurrent connections from ntfy.zig without GIL contention.

## Files

- `fake_ntfy.py` — stands in for ntfy: accepts the POST ntfy.zig sends
  (message body + `X-Title`/`X-Priority`/`X-Tags` headers), returns an
  ntfy-shaped JSON response, and can inject latency/failures/hangs via env
  vars to exercise ntfy.zig's forward-timeout and error-handling paths.
- `locustfile.py` — drives ntfy.zig's two webhook channels (`coolify`,
  `github`) with a realistic mix of successes, failures, malformed bodies,
  ignored event types, and bad-signature rejections.
- `run.sh` — builds ntfy.zig, starts the fake ntfy endpoint, starts
  ntfy.zig pointed at it, then runs a headless Locust run against ntfy.zig.

## Quick start

```bash
./run.sh
```

Tune with env vars: `LOCUST_USERS`, `LOCUST_SPAWN_RATE`, `LOCUST_RUN_TIME`,
`FAKE_NTFY_PORT`. See `run.sh` for defaults.

## Manual / interactive run

```bash
uv sync

# terminal 1: fake ntfy endpoint
uv run python fake_ntfy.py

# terminal 2: ntfy.zig itself, from the repo root
CHANNEL_1_TYPE=coolify \
CHANNEL_1_SECRET=stress-coolify-secret \
CHANNEL_1_NTFY_URL=http://127.0.0.1:9999/stress-coolify \
CHANNEL_1_NTFY_TOKEN=tk_stress \
CHANNEL_2_TYPE=github \
CHANNEL_2_SECRET=stress-github-secret \
CHANNEL_2_NTFY_URL=http://127.0.0.1:9999/stress-github \
CHANNEL_2_NTFY_TOKEN=tk_stress \
zig build run

# terminal 3: Locust web UI at http://localhost:8089
uv run locust -f locustfile.py --host http://127.0.0.1:8085
```

If you change `COOLIFY_SECRET`/`GITHUB_SECRET` env vars for `locustfile.py`,
set matching `CHANNEL_*_SECRET` values for ntfy.zig — the GitHub webhook
path is derived from the secret (see `src/github.zig`), so they must match
for requests to route correctly.

## Simulating a flaky/slow ntfy

```bash
FAKE_NTFY_DELAY_MS=200 FAKE_NTFY_FAIL_RATE=0.05 FAKE_NTFY_TIMEOUT_RATE=0.01 \
    uv run python fake_ntfy.py
```

`FAKE_NTFY_TIMEOUT_RATE` sleeps past ntfy.zig's 10s `ntfy_timeout`
(`src/main.zig`), letting you confirm the timeout/select race actually
fires under load instead of just in unit tests.

## Observing results

- `curl http://127.0.0.1:9999/stats` — request counts seen by the fake
  ntfy endpoint.
- `curl http://127.0.0.1:9090/metrics` — ntfy.zig's own Prometheus metrics
  (forwarded/failed counts, forward latency) on its internal port.
- Locust's own summary table (headless `--print-stats`, or the web UI).
