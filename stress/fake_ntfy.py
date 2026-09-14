"""Fake ntfy publish endpoint, for pointing ntfy.zig at during stress tests.

Mimics the bits of ntfy's POST /<topic> publish API that ntfy.zig actually
uses: it reads X-Title/X-Priority/X-Tags headers and the body as the message,
optionally checks a bearer token, and returns a 200 with an ntfy-shaped JSON
body. No real fan-out/persistence — it just counts requests and can be told
to inject latency or failures so the stress test can exercise ntfy.zig's
timeout/retry-adjacent code paths (see ntfy_timeout in src/main.zig).

Runs on stdlib http.server.ThreadingHTTPServer, which is what actually
benefits from a free-threaded (3.14t) interpreter here: each connection gets
a real OS thread with no GIL serializing them, so this can soak up concurrent
load from ntfy.zig without becoming the bottleneck itself.
"""

from __future__ import annotations

import json
import os
import random
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("FAKE_NTFY_HOST", "127.0.0.1")
PORT = int(os.environ.get("FAKE_NTFY_PORT", "9999"))
REQUIRED_TOKEN = os.environ.get("FAKE_NTFY_TOKEN")  # e.g. "tk_stress" ; None = no check
DELAY_MS = float(os.environ.get("FAKE_NTFY_DELAY_MS", "0"))
FAIL_RATE = float(os.environ.get("FAKE_NTFY_FAIL_RATE", "0"))  # 0.0-1.0
TIMEOUT_RATE = float(os.environ.get("FAKE_NTFY_TIMEOUT_RATE", "0"))  # 0.0-1.0, hangs past ntfy.zig's 10s deadline

_stats_lock = threading.Lock()
_stats = {"received": 0, "ok": 0, "rejected": 0, "unauthorized": 0, "simulated_timeout": 0}


def _record(key: str) -> None:
    with _stats_lock:
        _stats[key] += 1


class FakeNtfyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - stdlib signature
        pass  # quiet by default; stats are printed by the main loop instead

    def do_GET(self) -> None:  # noqa: N802 - stdlib signature
        if self.path == "/stats":
            body = json.dumps(_stats).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self) -> None:  # noqa: N802 - stdlib signature
        _record("received")

        content_length = int(self.headers.get("Content-Length", "0"))
        message = self.rfile.read(content_length) if content_length else b""

        if REQUIRED_TOKEN is not None:
            expected = f"Bearer {REQUIRED_TOKEN}"
            if self.headers.get("Authorization") != expected:
                _record("unauthorized")
                self._respond(401, {"code": 40101, "error": "unauthorized"})
                return

        if TIMEOUT_RATE and random.random() < TIMEOUT_RATE:
            _record("simulated_timeout")
            time.sleep(15)  # longer than ntfy.zig's 10s ntfy_timeout
            return

        if DELAY_MS:
            time.sleep(DELAY_MS / 1000.0)

        if FAIL_RATE and random.random() < FAIL_RATE:
            _record("rejected")
            self._respond(500, {"code": 50000, "error": "simulated failure"})
            return

        topic = self.path.lstrip("/") or "stress"
        title = self.headers.get("X-Title", "")
        priority = self.headers.get("X-Priority", "3")
        tags = self.headers.get("X-Tags", "")

        _record("ok")
        self._respond(
            200,
            {
                "id": uuid.uuid4().hex[:12],
                "time": int(time.time()),
                "event": "message",
                "topic": topic,
                "title": title,
                "message": message.decode("utf-8", errors="replace"),
                "priority": int(priority) if priority.isdigit() else 3,
                "tags": [t for t in tags.split(",") if t],
            },
        )

    def _respond(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def _print_stats_periodically(stop: threading.Event) -> None:
    while not stop.wait(5):
        with _stats_lock:
            snapshot = dict(_stats)
        print(f"[fake-ntfy] {snapshot}", flush=True)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), FakeNtfyHandler)
    server.daemon_threads = True

    stop = threading.Event()
    reporter = threading.Thread(target=_print_stats_periodically, args=(stop,), daemon=True)
    reporter.start()

    print(
        f"[fake-ntfy] listening on http://{HOST}:{PORT} "
        f"(delay={DELAY_MS}ms fail_rate={FAIL_RATE} timeout_rate={TIMEOUT_RATE} "
        f"auth={'required' if REQUIRED_TOKEN else 'off'})",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.shutdown()


if __name__ == "__main__":
    main()
