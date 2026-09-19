# ntfy.zig

A tiny relay that turns webhooks from [Coolify](https://coolify.io) and
GitHub (Actions runs, Deployments) into proper [ntfy](https://ntfy.sh) push
notifications. Single static binary (Zig, `-target x86_64-linux-musl`), no
runtime, no dependencies — built for a `FROM scratch` container.

## Why this exists

Coolify's webhook notification channel POSTs its own fixed JSON schema
(`event`, `message`, `success`, `application_name`, `project`,
`environment`, ...) with **no way to set custom headers or an auth token**
(see `SendWebhookJob`/`WebhookChannel` in Coolify's source — it's a plain
`Http::post($url, $payload)`, nothing configurable). Two consequences:

- ntfy requires auth (if you've closed it off with
  `auth-default-access: deny-all`, which you should) — but there's nowhere
  in Coolify's UI to attach a token or header.
- Even authenticated, POSTing Coolify's JSON straight at an ntfy topic URL
  doesn't produce a useful notification: ntfy only parses a JSON *publish*
  payload when you POST to its root URL with a `topic` field in the body;
  POSTed to a topic path instead, the whole raw JSON becomes the literal
  message text.

This relay sits in between: Coolify POSTs to a secret path on this relay
(no auth needed on that leg — the path *is* the auth, since Coolify has
nowhere to put a header), the relay reshapes the payload into a real
title/message/priority, and forwards it to ntfy with a proper
`Authorization` header.

## Config

The relay serves one or more **channels**, configured in a JSON file whose
path is given by `CONFIG_FILE`. Each channel picks its own ntfy target, so
e.g. Coolify can post to one topic/token and GitHub to another. In Coolify,
put the file in via Persistent Storage → Add → File Mount (destination path
e.g. `/config.json`) and set `CONFIG_FILE=/config.json`.

```json
{
  "channels": [
    {
      "type": "coolify",
      "secret": "<secret>",
      "ntfy_url": "https://ntfy.example.com/coolify",
      "ntfy_token": "<ntfy token>"
    },
    {
      "type": "github",
      "secret": "<webhook secret>",
      "ntfy_url": "https://ntfy.example.com/github",
      "ntfy_token": "<other ntfy token>",
      "deploy": {
        "workflow": "Docker build",
        "branch": "main",
        "url": "https://coolify.example.com/api/v1/deploy?uuid=<app uuid>&force=false",
        "token": "<Coolify API token>"
      }
    }
  ]
}
```

Unknown fields are rejected at startup, so a typo in a key fails loudly
instead of silently disabling something.

Two channel types are supported today:

- **`coolify`** — authenticated by a secret path segment: point Coolify's
  webhook at `http://host:8085/webhook/<secret>` — any other path (or method)
  gets a 404. The path *is* the auth, since Coolify's webhook config has
  nowhere to put a header or token.
- **`github`** — GitHub Actions (`workflow_run`) and Deployments
  (`deployment_status`) events. Unlike Coolify, GitHub webhooks support a
  real shared secret: each delivery is signed with HMAC-SHA256 in the
  `X-Hub-Signature-256` header, and this relay verifies it. A request with a
  missing or invalid signature is rejected with `401` and never forwarded.
  Everything else (other event types, or a `workflow_run`/`deployment_status`
  that isn't yet in a terminal state) is acknowledged with `200` and silently
  dropped, so a webhook subscribed to "everything" won't spam ntfy.
  `secret` is the same value you paste into the webhook's "Secret" field in
  GitHub (Settings → Webhooks → Add webhook). The payload URL isn't the
  secret itself; it's logged at startup (`github channel: payload URL path is
  /webhook/github/<hex>`), so start the relay first and read the URL to use
  from its logs. Content type: `application/json`. Under "Which events would
  you like to trigger this webhook?", select individual events: **Workflow
  runs** and **Deployment statuses**.

### Deploying from a GitHub workflow

A `github` channel can also redeploy an app when your image build finishes:

```
push to main → GitHub Actions builds & pushes to GHCR
  → GitHub sends a `workflow_run` webhook to the relay
  → relay verifies the signature, sees a successful "Docker build" run on `main`
  → relay calls Coolify's deploy URL with `Authorization: Bearer <token>`
  → relay sends one ntfy message with the run result + "Coolify deploy triggered"
```

The `deploy` block is both the trigger and the action: it fires on a
**successful** `workflow_run` whose workflow name is exactly `workflow` and
whose branch is `branch` (default `main`), then does a `GET` on `url` with
`token`. If Coolify rejects it or doesn't answer within 10s, the ntfy
notification says `Coolify deploy FAILED` and goes out at top priority.
`url` is Coolify's deploy webhook (`/api/v1/deploy?uuid=<uuid>`); `token` is
an API token with deploy permission (Keys & Tokens → API Tokens; the API
must be enabled in Coolify's settings). `deploy` is only allowed on `github`
channels. Note the trigger is the workflow *finishing*, which is after the
image push, so Coolify never pulls a half-published image.

A redelivered webhook (GitHub's "Redeliver" button) deploys again — there is
no de-duplication.

Each `ntfy_token` should be scoped to `write-only` on that one topic
(`ntfy token add <user>`) — don't hand this relay an admin token.

Listens on `:8085` for webhooks. `GET /health` (liveness check) and
`GET /metrics` (request/forward counters in Prometheus text format, see
`src/metrics.zig`) are on a separate `:9090` instead, so exposing the
webhook port to the internet doesn't also expose them — the Dockerfile
doesn't `EXPOSE` 9090; reach it over the container network (e.g. point a
Prometheus scrape target at `<container>:9090`) rather than publishing it.

## Build

```bash
zig build -Doptimize=ReleaseSmall                              # native
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall   # deploy target
zig build test                                                 # unit tests
docker build -t ntfy.zig .
```

## Gotcha worth keeping in mind if you touch `src/main.zig`

Zig 0.16's `std.http.Server`, when a request has neither `Content-Length`
nor `Transfer-Encoding: chunked`, hands you the **raw, unbounded connection
reader** as the body reader (`bodyReader` in `std/http.zig`) — reading from
it blocks until the peer closes the connection. Confirmed live: a bare
`curl -X POST` (no body) against this relay deadlocked the connection
indefinitely, because `request.respond()` itself calls this same body-drain
path internally (via `discardBody`) whenever it tries to keep the
connection alive for reuse. Two things fix it, both present in
`src/main.zig`:

1. Only attempt to read a body at all when `content_length != null` or
   `transfer_encoding == .chunked` — treat anything else as an empty body.
2. Pass `.keep_alive = false` on every `request.respond(...)` call, so
   `discardBody` never tries to drain a body on your behalf regardless of
   how a client framed (or didn't frame) its request.

This relay only ever serves single, low-volume requests, so giving up
keep-alive costs nothing.

A related trap: `std.http.Server.Request`'s own doc comment warns that
"pointers in this struct are invalidated when the request body stream is
initialized" — and it means it. Confirmed live: reading a request's body via
`readerExpectContinue`/`allocRemaining` and *then* reading `request.head.target`
or `request.head_buffer` hands back poisoned `undefined` memory in a debug
build (a hard segfault) rather than the bytes you expect. `request.head.target`
and `.method` are plain values/slices captured at `receiveHead()` time and stay
valid right up until the body reader is touched — so this relay finishes
everything that needs them (the `/health` check, route matching, and copying
out `request.head_buffer` for a channel that reads request headers) *before*
reading the body, not after.
