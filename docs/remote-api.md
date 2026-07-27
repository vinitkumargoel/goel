# Remote JSON API

Goel° can serve a small HTTP control surface from your own machine — the same server that
backs the web portal and the headless Linux daemon. This document describes it exactly as
implemented in `Sources/GoelCore/Remote/RemoteRouter.swift` and
`RemoteControlServer.swift`.

Enable it in **Settings → Web Access**. Nothing is relayed through any third-party server:
the listener is on your machine and reaches only whoever you let reach it.

> **The portal does not do TLS itself.** Put it behind a reverse proxy, a VPN or Tailscale
> before exposing it beyond loopback.

---

## Authentication

Three ways in, checked in this order:

1. **Session cookie** — `goel_session`, set by `POST /login`. `HttpOnly`, `SameSite=Strict`,
   `Path=/`, with a `Max-Age` from the configured session length.
2. **Open portal** — if `requireAuth` is off, everything passes. Only sane on a loopback
   bind.
3. **Bearer token** — `Authorization: Bearer <token>`, or `?token=<token>` in the query
   string. This is the path for scripts and the browser extension.

The token comparison is constant-time (it examines every byte regardless of where the
first mismatch is), so response timing cannot be used to recover it prefix-by-prefix.

A `GET /` carrying a valid `?token=` is also **promoted to a real session cookie** and served
the portal page, which is what makes the QR code and "Copy Link" in **Settings → Web Access**
work as a one-tap pairing link from a phone — the token authenticates the first request and
the cookie carries the rest. The portal's own JavaScript then strips `token=` out of the
address bar with `history.replaceState`, so the secret does not linger in the URL bar, a
bookmark or a screenshot. It is still a secret in a link: treat a shared QR image as a shared
password.

```sh
export GOEL="http://127.0.0.1:8899"
export TOKEN="…"                     # Settings → Web Access

curl -s -H "Authorization: Bearer $TOKEN" "$GOEL/api/tasks"
curl -s "$GOEL/api/tasks?token=$TOKEN"       # equivalent
```

### Failure modes

| Situation | Response |
|---|---|
| No/wrong credential on `/api/*` | `401` — `Not signed in. Open / to log in, or pass ?token=<token>.` |
| No/wrong credential on a non-`/api` `GET` | `302` redirect to `/login` |
| Backend shutting down | `503 Service Unavailable` |
| Any `POST` while read-only mode is on | `403` — `Read-only mode — changes are disabled from the web.` |
| Missing or malformed `id`/`file` parameter | `400 Bad Request` |
| `id` names a task that does not exist | `404 Not Found` |
| Unknown method/path pair | `404 Not Found` |

### Read-only mode

When read-only is enabled, **every `POST` is refused with 403** before routing. All
mutations in this API are POSTs, so read-only genuinely means read-only. Reads and media
streaming continue to work.

### Response headers

Every router response carries:

```
Cache-Control: no-store
Content-Security-Policy: default-src 'none'; script-src 'self';
  style-src 'self'; img-src 'self' data:; media-src 'self';
  connect-src 'self'; form-action 'self'; base-uri 'none'
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: no-referrer
Connection: close
```

### Limits

| Limit | Value |
|---|---|
| Concurrent connections | 32 |
| Concurrent SSE streams | 4 (a fifth gets `503 Too many live streams`) |
| Login throttle | Per client IP: 5 free attempts, then a 5-second lock doubling on each further failure, capped at 15 minutes |
| Concurrent password verifications | capped; excess gets `429 Too Many Requests` |

A throttled login gets `429 Too Many Requests` with a `Retry-After` header; the client
address is the socket's peer address, never a header, so it cannot be spoofed to dodge the
penalty. A correct password clears that client's record immediately. The free-attempt count
and the first delay are configurable in **Settings → Web Access** (defaults above); the
15-minute ceiling is not.

Portal passwords are stored as `v2$saltHex$hashHex` — PBKDF2-HMAC-SHA256, 210,000
iterations, 16-byte random salt. A legacy `v1` (iterated SHA-256) format is still
verified for upgrades. Session IDs are 32 random bytes.

---

## The 14 JSON routes

All of these live in `RemoteRouter.handle(_:sessionAuthed:)`. Parameters are query-string
parameters unless stated otherwise. `id` is always a task UUID string.

### Reads

#### `GET /api/config`

Portal configuration, used by the page to render itself.

```json
{ "username": "admin", "readOnly": false, "requireAuth": true,
  "theme": "frost-dark", "appName": "Goel°" }
```

#### `GET /api/tasks`

Every task in the queue, as an array of [TaskRow](#taskrow). This is the same payload the
SSE stream pushes.

#### `GET /api/task?id=<uuid>`

One task in full: a `TaskRow` plus files, trackers, peer connections and piece
availability. See [TaskDetail](#taskdetail). `400` if `id` is missing or malformed, `404`
if no such task.

#### `GET /api/history`

Completed downloads, most recent first, capped at 500 entries. Array of
[HistoryRow](#historyrow).

### Queue mutations

Each returns `{"ok":true}` on success.

#### `POST /api/pause-all`

Pause every task. No parameters.

#### `POST /api/resume-all`

Resume every task. No parameters.

#### `POST /api/pause?id=<uuid>`

Pause one task.

#### `POST /api/resume?id=<uuid>`

Resume one task.

#### `POST /api/retry?id=<uuid>`

Retry a failed task.

#### `POST /api/recheck?id=<uuid>`

Force a re-verification of the data already on disk. CPU-heavy on large torrents.

#### `POST /api/remove?id=<uuid>[&data=1]`

Remove a task from the queue. With `data` truthy, the downloaded data is deleted too;
otherwise the files are left on disk.

Truthy values are `1`, `true`, `yes`, `on` (case-insensitive). Anything else, including
an absent parameter, is false — so the destructive behaviour has to be asked for
explicitly.

#### `POST /api/file-priority?id=<uuid>&file=<int>&prio=<priority>`

Set the priority of one file inside a multi-file task. `file` is the integer file ID from
`TaskDetail.files[].id`.

`prio` is one of `skip`, `low`, `high` — **anything else, including an absent value,
means `normal`.** `400` if `id` or `file` is missing or malformed.

#### `POST /api/add`

The only route with a JSON request body.

```jsonc
{
  "url": "https://example.org/a.iso\nmagnet:?xt=urn:btih:…",  // required
  "folder": "/Users/me/Downloads/isos",                        // optional
  "priority": "high",                                          // optional: skip|low|normal|high
  "paused": false,                                             // optional, default false
  "network": "single:eth0"                                     // optional, default "auto"
}
```

- `url` is **newline-separated**: one request can add a batch. Each line is parsed as a
  download source; unparseable lines are skipped silently.
- If no line parses into a valid source, the response is `400 Bad Request`.
- `folder` is trimmed; empty means "use the per-source default".
- `network` chooses the interface(s) this download egresses, overriding the server-wide
  aggregation policy. One of:

  | Value | Meaning |
  |---|---|
  | `auto` (or absent) | Follow the server-wide policy |
  | `single:<iface>` | Every connection egresses that one interface |
  | `aggregate` | Split across every eligible interface |
  | `aggregate:<a>,<b>` | Split across exactly these |

  A **malformed** value is `400 Bad Request` and adds nothing — it is not downgraded to
  `auto`, because "I named one interface and it used all of them" is the wrong surprise.
  An interface that is valid but *gone by the time the download starts* is a different
  case: the download runs on the default route and the reason is logged, rather than
  failing over a cable someone unplugged. HTTP(S) only; other protocols ignore it.

Response is a pair of counts, not `{"ok":true}`. `refused` is always present:

```json
{ "added": 2, "refused": 0 }
```

> **Path containment.** A `folder` outside the configured downloads root fails the whole
> request with `403 Forbidden` and adds nothing — it is **not** silently redirected to the
> default. Without the check, an authenticated client could drop a file into an auto-run
> location such as `~/Library/LaunchAgents`; without the refusal, a client told "added"
> could not tell where the file actually went.
>
> **Internal-address guard.** Every URL-bearing source is screened against loopback, the
> link-local/cloud-metadata range and the unspecified address, **by resolved address** — a
> hostname that resolves into those ranges is refused too, as are the integer, octal, hex
> and IPv4-mapped-IPv6 spellings. Refused lines are counted in `refused`; if nothing in the
> batch survives, the response is `403 Forbidden`. Private LAN ranges (`10/8`, `172.16/12`,
> `192.168/16`) are deliberately allowed, since pulling from a NAS is the point. Note that
> a screened URL is only screened at the point of adding: an allowed host that **redirects**
> to an internal address is followed, and the child URIs inside an accepted HLS playlist are
> checked for scheme but not for address.

#### `POST /api/history-remove?id=<uuid>`

Delete one history entry.

#### `GET /api/network`

Every interface the daemon may bind to, plus the current aggregation policy.

```jsonc
{
  "aggregation": true,          // is splitting enabled server-wide
  "streamsPerAdapter": 2,       // connections opened per interface, 1-8
  "selected": ["eth0"],         // interfaces splitting may use; [] = every eligible one
  "reason": null,               // why it is NOT splitting right now, else null
  "locked": false,              // GOEL_AGGREGATION is set in /etc/goel/config
  "adapters": [
    { "name": "eth0", "label": "Ethernet (eth0)", "type": "wired",
      "ipv4": "192.168.0.4", "expensive": false, "eligible": true }
  ]
}
```

`eligible` is false when the interface exists but cannot be bound right now — a proxy or a
VPN default route is in force. Binding a socket to a NIC bypasses both, so those are hard
exclusions, not preferences, and a `network` choice naming an ineligible interface falls
back to the default route.

`locked` is true when the environment pins `GOEL_AGGREGATION`. The setting can still be
changed through the API, but the next service restart reverts it — so a client should say
so rather than implying the change is permanent.

#### `POST /api/network`

Change the server-wide aggregation policy. Every field is optional; an absent field is
left alone.

```jsonc
{
  "aggregation": true,          // on/off
  "adapters": ["eth0", "wlan0"],// [] = every eligible interface
  "streams": 2                  // 1-8; `streamsPerAdapter` is accepted too, so the
                                // object GET returns can be posted straight back
}
```

`400 Bad Request` — and nothing is applied — if `adapters` holds something that is not an
interface name, or `streams` is outside 1–8. The response is the same object `GET
/api/network` returns, reflecting what the server actually decided (including a `reason`
explaining why turning it on did not start any splitting).

Running downloads keep the interfaces they started on; the change applies to new ones.

---

## Routes owned by the server shell

These are not in the pure router — they need sockets or session state — but they are part
of the same HTTP surface.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/` | The HTML shell for the control page |
| `GET` | `/assets/<name>` | The compiled portal UI — **unauthenticated**, see below |
| `GET` | `/login` | Login form (redirects to `/` if already signed in, or if auth is off) |
| `POST` | `/login` | Sign in. Accepts JSON **or** `application/x-www-form-urlencoded`, so the portal works without JavaScript. Sets `goel_session` |
| `GET`/`POST` | `/logout` | Clears the cookie and invalidates open streams |
| `GET` | `/api/events` | Server-sent events: the full task list pushed roughly every 1.5 s |
| `GET` | `/stream?id=<uuid>` | Byte-range media streaming of a task's file |

### `GET /assets/<name>`

The portal's JavaScript and CSS. Source lives in `/portal` (React + TypeScript) and is
compiled into `Sources/GoelCore/Remote/Generated/PortalBundle.swift`, so the daemon serves
it from memory with no filesystem access — a lookup against an unknown name is a `404`,
and there is no path to traverse.

Filenames carry a content hash (`portal-<hash>.js`), which makes them immutable:

```
Cache-Control: public, max-age=31536000, immutable
```

New bytes produce a new URL, so a cached copy can never be served against a newer shell.
Every other response on this surface remains `no-store`.

**These four files are served before the auth gate, deliberately.** The login page needs
its own stylesheet and script before anyone has signed in; gating them would render it
unstyled and inert. Nothing in them is a secret — the bundle is byte-identical for every
user and every deployment and contains no configuration. The per-session values (username,
theme, read-only) live in the page shell at `/`, which stays behind the gate.

### `GET /api/events` (SSE)

```
Content-Type: text/event-stream
Cache-Control: no-store
Connection: keep-alive
```

Each frame is `data: <json>\n\n`, where the JSON is the same array of `TaskRow` that
`/api/tasks` returns. The stream ends when the client disappears, when the server
restarts, or when credentials are rotated. Capped at 4 concurrent streams.

```sh
curl -N -H "Authorization: Bearer $TOKEN" "$GOEL/api/events"
```

### `GET /stream?id=<uuid>`

Serves the task's payload with `Accept-Ranges: bytes`, honouring a `Range` header
(`206 Partial Content` with `Content-Range`). The range is clamped to the bytes that
verifiably exist on disk, so you cannot read past what has actually downloaded.

| Response | Meaning |
|---|---|
| `200` | Full body (or an empty body for a finished 0-byte payload) |
| `206` | Partial content for a satisfiable `Range` |
| `401` | Not authorised |
| `404` | No such download, or the file is missing on disk |
| `409` | Not streamable yet — finish the download or enable sequential mode |
| `416` | Range not satisfiable |

---

## Payload shapes

### TaskRow

| Field | Type | Notes |
|---|---|---|
| `id` | string | Task UUID |
| `name` | string | |
| `status` | string | Display name, e.g. `"Downloading"` |
| `statusToken` | string | Stable token: `queued`, `metadata`, `downloading`, `verifying`, `paused`, `seeding`, `completed`, `failed` |
| `kind` | string | `http`, `torrent`, `hls`, `ftp`, `sftp` |
| `progress` | number | Fraction complete, 0–1 |
| `downSpeed` | number | Bytes/second |
| `upSpeed` | number | Bytes/second |
| `totalBytes` | number \| null | Null until known (e.g. a magnet awaiting metadata) |
| `doneBytes` | number | |
| `upBytes` | number | |
| `ratio` | number | Share ratio |
| `seeds` | number \| null | |
| `conns` | number | Active connections |
| `addedAt` | number | Unix seconds |
| `etaSeconds` | number \| null | |
| `error` | string \| null | Present only when failed |
| `source` | string | The original locator |
| `multiFile` | boolean | |
| `fileCount` | number | |
| `streamable` | boolean | Whether `/stream` would currently work |

### TaskDetail

`TaskRow` under `row`, plus:

| Field | Type | Notes |
|---|---|---|
| `savePath` | string | |
| `sequential` | boolean | Sequential-download mode |
| `infoHash` | string \| null | Torrents only |
| `files` | FileRow[] | |
| `trackers` | TrackerRow[] | |
| `connections` | ConnRow[] | Peers / connections |
| `pieces` | number[] | Per-piece availability |
| `server` | string \| null | Remote server banner, where known |
| `mimeType` | string \| null | |

**FileRow** — `id` (int, use with `/api/file-priority`), `name` (path within the task),
`size`, `done`, `progress`, `priority` (`skip`\|`low`\|`normal`\|`high`).

**TrackerRow** — `url`, `host`, `tier`, `status`, `seeds`, `leeches`, `message`.

**ConnRow** — `id`, `label`, `detail`, `down`, `up`, `progress`, `adapterId`,
`adapterLabel`.

### HistoryRow

`id`, `name`, `kind`, `totalBytes` (nullable), `savePath`, `completedAt` (Unix seconds),
`source`.

---

## Worked example

```sh
#!/usr/bin/env bash
set -euo pipefail
GOEL="http://127.0.0.1:8899"
AUTH=(-H "Authorization: Bearer $TOKEN")

# Add two downloads, paused, into a folder inside the downloads root
curl -s "${AUTH[@]}" -X POST "$GOEL/api/add" \
  -H 'content-type: application/json' \
  -d '{"url":"https://example.org/a.iso\nhttps://example.org/b.iso","paused":true}'
# → {"added":2,"refused":0}

# List them
curl -s "${AUTH[@]}" "$GOEL/api/tasks" | jq -r '.[] | "\(.id)  \(.statusToken)  \(.name)"'

# Pin a download to one interface (see what this machine has first)
curl -s "${AUTH[@]}" "$GOEL/api/network" | jq -r '.adapters[] | "\(.name)  \(.ipv4)  eligible=\(.eligible)"'
curl -s "${AUTH[@]}" -X POST "$GOEL/api/add" \
  -H 'content-type: application/json' \
  -d '{"url":"https://example.org/big.iso","network":"single:eth0"}'

# Start everything
curl -s "${AUTH[@]}" -X POST "$GOEL/api/resume-all"
# → {"ok":true}

# Skip a file inside a torrent
curl -s "${AUTH[@]}" -X POST \
  "$GOEL/api/file-priority?id=$TASK_ID&file=3&prio=skip"

# Remove a task but keep the data on disk
curl -s "${AUTH[@]}" -X POST "$GOEL/api/remove?id=$TASK_ID"
```

---

## Notes for integrators

- **`POST /api/add` and `POST /api/network` are the only routes with a request body.**
  Everything else takes query parameters.
- **Unknown `prio` values silently become `normal`.** Validate before sending if that
  matters to you.
- **`data=` on remove defaults to false.** Deletion must be requested explicitly.
- **Poll `/api/tasks` or subscribe to `/api/events`, not both.** The payload is identical;
  SSE avoids the polling cost, but only 4 streams are allowed at once.
- **Every response is `Connection: close`.** Do not expect keep-alive on the JSON routes.
- **Commercial use of this API inside an organisation needs a licence** — building
  internal tooling on GoelCore or on these routes is exactly the case a commercial
  licence covers. See the
  [commercial licensing page](https://goel.vinitk.dev/commercial).
