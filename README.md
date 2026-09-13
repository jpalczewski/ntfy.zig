# ntfy.zig

A tiny relay that turns [Coolify](https://coolify.io)'s generic "Webhook"
notification channel into a proper [ntfy](https://ntfy.sh) push
notification. Single static binary (Zig, `-target x86_64-linux-musl`), no
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

## Config (environment variables)

| Var | Meaning |
|---|---|
| `RELAY_SECRET` | Coolify's webhook URL must be `http://host:8085/webhook/<RELAY_SECRET>` — any other path (or method) gets a 404. |
| `NTFY_URL` | Full ntfy publish URL, e.g. `https://ntfy.example.com/coolify`. |
| `NTFY_TOKEN` | ntfy access token (`ntfy token add <user>`) for a user scoped to `write-only` on that one topic — don't hand this relay an admin token. |

Listens on `:8085`.

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
