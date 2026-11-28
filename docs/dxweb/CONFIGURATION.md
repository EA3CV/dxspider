# DXWeb configuration reference

DXWeb and DXWeb Admin read configuration in this order, highest first:

1. environment variables (systemd `Environment=` or `EnvironmentFile=`)
2. `/spider/local_data/dxweb.conf` (flat JSON keyed by variable name)
3. built-in defaults

Environment variables always win, so an existing unit file keeps working
after a configuration file is added.

Inspect the result:

```bash
perl /spider/dxweb/dxwebctl config show
perl /spider/dxweb/dxwebctl config check
```

`show` prints the effective values. `check` also validates types, paths,
TLS files and port conflicts.

---

## Core

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `DXS_HOST` | `127.0.0.1` | both | DXSpider `IntMsg` listener address |
| `DXS_PORT` | `27754` | both | DXSpider `IntMsg` listener port |
| `DXSPIDER_ROOT` | `/spider` | both | DXSpider tree; admin history and defaults |
| `HTTP_HOST` | `0.0.0.0` | DXWeb | Public listen address |
| `HTTP_PORT` | `7380` | DXWeb | Public listen port |
| `DXWEB_HOST` | `0.0.0.0` | Admin | Admin listen address |
| `DXWEB_PORT` | `7381` | Admin | Admin listen port |
| `DXWEB_CLIENT_HOST` | `127.0.0.1` | Admin | Where Admin reaches DXWeb |
| `DXWEB_CLIENT_PORT` | `7380` | Admin | DXWeb backend port |
| `DXWEB_CLIENT_SCHEME` | `http` | Admin | DXWeb backend scheme |
| `DXWEB_SCHEME` | `http` | both | Scheme served by the application |
| `MOJO_REVERSE_PROXY` | `0` | both | Trust `X-Forwarded-*` from a known proxy |

If `MOJO_REVERSE_PROXY` is `1`, only a trusted proxy must be able to reach
the application. Do not enable it for direct clients.

## TLS

| Key | Default | Meaning |
|---|---|---|
| `DXWEB_TLS_CERT` | empty | Certificate file, required for direct HTTPS |
| `DXWEB_TLS_KEY` | empty | Private key, required for direct HTTPS |

When `DXWEB_SCHEME=https` and the reverse proxy is disabled, both files
must exist and be readable. With Nginx, TLS is configured in Nginx and the
applications normally listen on plain HTTP on loopback.

## Limits

| Key | Default | Meaning |
|---|---|---|
| `DXWEB_WS_PER_IP_LIMIT` | `12` | Concurrent WebSocket clients per address |
| `DXWEB_WS_UNVERIFIED_SEC` | `90` | Grace period before an unauthenticated client is dropped |
| `DXWEB_WS_AUTH_PER_MIN` | `12` | Authentication attempts per minute per address |
| `MAX_WS_CLIENTS` | `2000` | DXWeb client cap |
| `MAX_WS_MSG_BYTES` | `65536` | DXWeb inbound message cap |
| `MAX_CLIENTS` | `64` | Admin client cap |
| `MAX_WS_MESSAGE_BYTES` | `524288` | Admin message cap |
| `MAX_BROWSER_MESSAGE_BYTES` | `65536` | Admin browser request cap |
| `MAX_PENDING_TOTAL` | `256` | Admin pending requests, total |
| `MAX_PENDING_PER_CLIENT` | `16` | Admin pending requests per client |
| `RECONNECT_SEC` | `3` | Delay before reconnecting to DXSpider |
| `REQUEST_TIMEOUT_SEC` | `30` | Upstream request timeout |

Lower these on small systems or when a single client misbehaves. The health
endpoints and the admin Web panel expose queue depth and dropped frames.

## Registration and Turnstile

| Key | Default | Meaning |
|---|---|---|
| `DXWEB_TURNSTILE_CONFIG` | `/etc/dxweb/turnstile.json` | Key file, mode 0600 |
| `DXWEB_HISTORY_DB` | `local_data/dxhistory.db` | Admin metrics database |
| `DXWEB_HISTORY_INTERVAL_SEC` | `30` | Metrics sample interval |

The Turnstile file is a JSON object:

```json
{
  "enabled": true,
  "site_key": "0x4AAAA...",
  "secret_key": "0x4AAAA..."
}
```

The application rejects a key file that is group- or world-readable.

## Secrets and non-schema variables

These are read directly by the applications and are not part of the
validation schema:

| Variable | Purpose |
|---|---|
| `DXWEB_SECRET` | Mojolicious session secret for DXWeb |
| `DXWEB_ADMIN_SECRET` | Session secret for Admin, falls back to `DXWEB_SECRET` |
| `DXWEB_MENU_ROOT` | Override the tree used by `dxweb-menu.pl` |
| `DXWEB_MENU_MANAGER` | Override the manager path |
| `DXWEB_INSTALL_LOG` | Installer log path |

Set secrets in an `EnvironmentFile` with mode 0600, not in the JSON file.

## Example

```json
{
  "DXS_HOST": "127.0.0.1",
  "DXS_PORT": 27754,
  "HTTP_HOST": "127.0.0.1",
  "HTTP_PORT": 7480,
  "DXWEB_HOST": "127.0.0.1",
  "DXWEB_PORT": 7481,
  "DXWEB_CLIENT_HOST": "127.0.0.1",
  "DXWEB_CLIENT_PORT": 7480,
  "MOJO_REVERSE_PROXY": 1,
  "DXWEB_WS_PER_IP_LIMIT": 8,
  "MAX_WS_CLIENTS": 500
}
```

This is the usual Nginx layout: the applications listen on loopback and
Nginx publishes 7380 and 7381.

After editing, restart the affected service:

```bash
sudo systemctl restart dxweb.service
sudo systemctl restart dxweb-admin.service
```
