"""Locust stress test for ntfy.zig's webhook relay.

Drives both channel types it supports (see src/coolify.zig, src/github.zig):

- coolify: POST /webhook/<secret> with a Coolify-shaped JSON body.
- github:  POST /webhook/github/<sha256(secret)[:8] hex> with an
  X-Hub-Signature-256 HMAC and an X-GitHub-Event header.

Point this at a running ntfy.zig with:

    CHANNEL_1_TYPE=coolify
    CHANNEL_1_SECRET=<COOLIFY_SECRET>
    CHANNEL_1_NTFY_URL=http://127.0.0.1:9999/stress-coolify
    CHANNEL_1_NTFY_TOKEN=<anything, fake_ntfy.py doesn't check it by default>
    CHANNEL_2_TYPE=github
    CHANNEL_2_SECRET=<GITHUB_SECRET>
    CHANNEL_2_NTFY_URL=http://127.0.0.1:9999/stress-github
    CHANNEL_2_NTFY_TOKEN=<anything>

and run: uv run locust -f locustfile.py --host http://127.0.0.1:8085

COOLIFY_SECRET/GITHUB_SECRET here must match the CHANNEL_*_SECRET values
above — see README.md for the matching defaults.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import random
import uuid

from locust import HttpUser, task, between

COOLIFY_SECRET = os.environ.get("COOLIFY_SECRET", "stress-coolify-secret")
GITHUB_SECRET = os.environ.get("GITHUB_SECRET", "stress-github-secret")

COOLIFY_PATH = f"/webhook/{COOLIFY_SECRET}"
GITHUB_PATH = "/webhook/github/" + hashlib.sha256(GITHUB_SECRET.encode()).hexdigest()[:16]

APPS = ["api", "worker", "frontend", "scheduler", "ingest"]
PROJECTS = ["acme", "globex", "initech"]
ENVIRONMENTS = ["production", "staging"]
BRANCHES = ["main", "release/1.4", "feature/stress-test"]


def _github_signature(body: bytes) -> str:
    digest = hmac.new(GITHUB_SECRET.encode(), body, hashlib.sha256).hexdigest()
    return f"sha256={digest}"


class NtfyZigUser(HttpUser):
    """Simulates a mix of Coolify and GitHub webhook deliveries."""

    wait_time = between(0.05, 0.5)

    def _post_coolify(self, payload: dict, label: str):
        self.client.post(COOLIFY_PATH, json=payload, name=f"{COOLIFY_PATH} [{label}]")

    def _post_github(self, body: bytes, event: str, label: str, *, signature: str | None = None):
        self.client.post(
            GITHUB_PATH,
            data=body,
            headers={
                "Content-Type": "application/json",
                "X-GitHub-Event": event,
                "X-Hub-Signature-256": signature or _github_signature(body),
            },
            name=f"{GITHUB_PATH} [{label}]",
        )

    # --- Coolify deployment webhooks -------------------------------------

    @task(5)
    def coolify_deploy_success(self):
        self._post_coolify(
            {
                "event": "deployment",
                "message": "Deployment finished",
                "success": True,
                "application_name": random.choice(APPS),
                "project": random.choice(PROJECTS),
                "environment": random.choice(ENVIRONMENTS),
            },
            "deploy ok",
        )

    @task(2)
    def coolify_deploy_failure(self):
        self._post_coolify(
            {
                "event": "deployment",
                "message": "Deployment failed: build exited with code 1",
                "success": False,
                "application_name": random.choice(APPS),
                "project": random.choice(PROJECTS),
                "environment": random.choice(ENVIRONMENTS),
            },
            "deploy fail",
        )

    @task(1)
    def coolify_malformed(self):
        # Not valid JSON at all -- exercises ntfy.zig's parse_fallback path.
        self.client.post(
            COOLIFY_PATH,
            data=b"not json",
            headers={"Content-Type": "application/json"},
            name=f"{COOLIFY_PATH} [malformed]",
        )

    # --- GitHub Actions / Deployments webhooks ----------------------------

    @task(5)
    def github_workflow_run_completed(self):
        body = json.dumps(
            {
                "action": "completed",
                "workflow_run": {
                    "display_title": "CI",
                    "name": "CI",
                    "conclusion": random.choice(["success", "success", "failure"]),
                    "head_branch": random.choice(BRANCHES),
                },
                "repository": {"full_name": f"acme/{random.choice(APPS)}"},
            }
        ).encode()
        self._post_github(body, "workflow_run", "workflow_run")

    @task(3)
    def github_deployment_status(self):
        body = json.dumps(
            {
                "deployment_status": {"state": random.choice(["success", "failure"])},
                "deployment": {"environment": random.choice(ENVIRONMENTS)},
                "repository": {"full_name": f"acme/{random.choice(APPS)}"},
            }
        ).encode()
        self._post_github(body, "deployment_status", "deployment_status")

    @task(1)
    def github_ping(self):
        body = json.dumps({"zen": "Keep it logically awesome.", "hook_id": random.randint(1, 999999)}).encode()
        self._post_github(body, "ping", "ping")

    @task(1)
    def github_ignored_event(self):
        # An event type ntfy.zig doesn't act on -- should be a cheap 200 (Ignored).
        body = json.dumps({"issue": {"title": str(uuid.uuid4())}}).encode()
        self._post_github(body, "issues", "ignored event")

    @task(1)
    def github_bad_signature(self):
        # Wrong secret -- should be a fast 401, exercising the rejection path.
        body = json.dumps({"action": "completed"}).encode()
        bad_sig = "sha256=" + hmac.new(b"wrong-secret", body, hashlib.sha256).hexdigest()
        self._post_github(body, "workflow_run", "bad signature", signature=bad_sig)
