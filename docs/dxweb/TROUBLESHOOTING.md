# DXWeb and DXWeb Admin troubleshooting

Work from the outside in: service, port, HTTP, WebSocket, then DXSpider.

```bash
systemctl status dxspider.service dxweb.service dxweb-admin.service
perl /spider/dxweb/dxwebctl status --json
perl /spider/dxweb/dxwebctl check
```

The installer and manager logs are at `/var/log/dxspider-install.log` and
through `journalctl`. The web applications write to stdout, so journald is
the first place to look.

---

## The page does not load

| Check | Command | Fix |
|---|---|---|
| Service active | `systemctl status dxweb.service` | Start it, read the journal |
| Port listening | `ss -ltnp | grep 7380` | Correct `HTTP_PORT` and restart |
| Firewall | `firewall-cmd` or `ufw status` | Open the public port only |
| Behind Nginx | `nginx -t` | Fix the proxy block, reload Nginx |
| DNS | `curl -I http://127.0.0.1:7380/` | If localhost works, the problem is the proxy or DNS |

A 502 from Nginx means the backend is not listening or the proxy points at
the wrong port. Direct mode uses 7380 and 7381. Nginx mode uses 7480 and 7481
internally.

## Blank page or unstyled page

1. Open the browser developer tools, Network tab, and reload.
2. A 404 for `app.js` or `style.css` means the static path is wrong. The
   files must be under `/spider/dxweb/public/`.
3. A CSP error in the console means a resource is loaded from an origin that
   the policy does not allow. The shipped policy allows only the same origin
   plus Cloudflare Turnstile.
4. An old cached page after an update is unusual because assets carry the
   release in the query string. A hard reload is still safe.
5. Check `curl -I http://127.0.0.1:7380/` for the security headers. See
   `dxweb/tools/check_http_surface.sh`.

## WebSocket rejected (403) or "disconnected"

The applications verify the browser `Origin` header against the request
host. A mismatch happens when a proxy rewrites `Host` but not `Origin`, or
when the page is opened through an unexpected hostname.

- Use the same public hostname in the browser and in the proxy
  configuration.
- With Nginx, set `proxy_set_header Host $host;` and forward the
  `Upgrade`/`Connection` headers.
- `MOJO_REVERSE_PROXY=1` is only for a trusted proxy. Do not enable it for
  direct clients.
- If the page is on HTTPS, the WebSocket must use `wss://`. The application
  chooses this from `location.protocol` automatically.

## Login fails or the dialog does not open

- DXWeb shows `DXSpider connection is not ready` when the node link is down.
  Check `dxwebctl status` and the `#WEB-n` connection in the DXSpider debug
  log (`set/debug web` on the console).
- The node must be listening on `DXS_HOST:DXS_PORT`, normally
  `127.0.0.1:27754`.
- DXWeb Admin requires a DXSpider privilege of at least 5. Administrative
  actions require 9. The web login never inherits SYSOP privilege from the
  callsign alone.
- An unregistered DXWeb user can log in read-only. If the node requires
  registration, request it with the Register button.
- Duplicate sessions: a second login for the same callsign replaces the old
  one only on the local console or DXWeb Admin. Otherwise the existing
  session is preserved.

## "DXWeb Admin" shows fewer panels than expected

The navigation hides SYSOP sections for low privilege. Log in with a
callsign that has privilege 9 for maintenance, registration and the Linux
terminal. The terminal can also be disabled server-side in
`dxweb-admin/config.pl` with `$enable_linux_terminal = 0`.

## Turnstile does not appear, or always fails

- The configuration file must be mode 0600 and readable by the service user.
  The application treats group or world readable files as broken.
- `enabled` must be `true`, and both keys must be present.
- The site key must belong to the same Cloudflare widget as the secret key.
- If the browser blocks `challenges.cloudflare.com`, the widget cannot load.
  The CSP already allows that origin.
- To disable Turnstile quickly, set `"enabled": false` and restart the
  service.

## Registration email or Telegram does not arrive

- Registration must be enabled in `local/DXVars.pm` and `DXReg` must be
  ready: `show/register` from the console.
- Email needs `$reg_email_enable`, a reachable SMTP host, port, user and
  password.
- Telegram needs a bot token and chat id. Test with `curl` first.
- Check the node log for SMTP or API errors.

## Configuration changes do not apply

Precedence is environment, then `local_data/dxweb.conf`, then defaults. An
`Environment=` value in the unit file wins over the file.

```bash
perl /spider/dxweb/dxwebctl config show
systemctl cat dxweb.service
systemctl cat dxweb-admin.service
```

Restart the affected service. `dxwebctl config set` only writes the file; it
does not restart anything.

## Version shown in the footer is old

The footer and asset URL use the running process release, read from
`dxweb/VERSION` or `dxweb-admin/VERSION` at startup. After `git pull`,
restart the service. The admin Overview compares running and installed
versions and marks a restart as pending.

## Port already in use

```bash
ss -ltnp | grep -E '7380|7381|7480|7481'
```

Change `HTTP_PORT` or `DXWEB_PORT` in `local_data/dxweb.conf`, then restart.
If Nginx is enabled, change the upstream ports to match.

## HTTPS certificate problems

- The certificate must cover the hostname used in the browser.
- The key must match the certificate.
- The files must be readable by the service account.
- With Nginx, TLS belongs in Nginx, not in the applications.
- `dxwebctl check` reports unreadable files and missing directories.

## High CPU, slow page, or dropped clients

- `dxwebctl status --json` shows queue depth, dropped frames and connected
  clients.
- Reduce `MAX_WS_CLIENTS`, `DXWEB_WS_PER_IP_LIMIT` or the spot feed rate.
- A very large number of RBN spots can be filtered at the node level; see
  `accept/rbn` and `RBN.mojo`.
- The admin Web panel shows backpressure and saturated channels.

## Collecting a useful report

Include:

- `dxwebctl status --json`
- `dxwebctl check`
- `journalctl -u dxweb.service -n 100 --no-pager`
- `journalctl -u dxweb-admin.service -n 100 --no-pager`
- DXWeb and DXWeb Admin versions from `/version.json`
- Browser name and version, and the console error text

Do not send passwords, Turnstile secret keys or private configuration.
