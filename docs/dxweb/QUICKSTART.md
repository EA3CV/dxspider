# DXWeb quick start

DXWeb is the browser client. DXWeb Admin is the supervision and
administration interface. Both are optional and both talk to the DXSpider
node through a local connection to the `IntMsg` listener on port 27754.

Recommended path: install everything with the main installer.

```bash
curl -fsSL https://raw.githubusercontent.com/EA3CV/dxspider/mojo/install.sh \
  -o /tmp/dxspider-install.sh
sudo bash /tmp/dxspider-install.sh --all --call <your-node-call>
```

It installs DXSpider, DXWeb and DXWeb Admin, creates the services and prints
the URLs.

---

## Adding the web applications to an existing node

```bash
cd /spider
sudo perl dxweb/dxweb-menu.pl
```

Choose `3` (both applications), then `2` (plan/install/update), then the
access mode: `1` direct, `2` Nginx. Review the plan and apply. The menu is
the supported interface; the manager below it is transactional and can roll
back.

Equivalent unattended command:

```bash
sudo perl /spider/dxweb/dxweb-manager.pl \
  --action install --root /spider --components both \
  --mode direct --scheme http --apply
```

---

## Default ports

| Service | Direct | Behind Nginx |
|---|---|---|
| DXWeb | 7380 | 7480 (internal) |
| DXWeb Admin | 7381 | 7481 (internal) |
| DXSpider IntMsg | 27754, localhost only | 27754, localhost only |
| DXSpider telnet | 7300 (example) | unchanged |

Do not expose 27754, 7480 or 7481 to the internet. Use HTTPS for any public
login, preferably through Nginx.

---

## First checks

```bash
systemctl status dxspider.service dxweb.service dxweb-admin.service
perl /spider/dxweb/dxwebctl status
perl /spider/dxweb/dxwebctl check
```

`dxwebctl status` reports the systemd state and the readiness endpoint for
each application. `dxwebctl check` also validates the configuration file.

Open `http://<server>:7380/` for DXWeb and `http://<server>:7381/` for DXWeb
Admin.

---

## First login

- **DXWeb**: enter your callsign. A registered callsign may also enter its
  password. Unregistered users get read-only access; use the Register button
  to request an account if the node has registration enabled.
- **DXWeb Admin**: requires a DXSpider privilege of at least 5. Actions such
  as registration changes, maintenance and the Linux terminal require
  privilege 9.

Web sessions never inherit SYSOP privilege from the callsign alone. A SYSOP
who logs in through DXWeb is a normal user. Only the server-authorised admin
path grants admin rights.

---

## Configuration

Settings can come from three places, in this order:

1. environment variables (systemd `Environment=` or `EnvironmentFile=`)
2. `/spider/local_data/dxweb.conf`, a flat JSON object
3. built-in defaults

Example:

```json
{
  "DXS_HOST": "127.0.0.1",
  "DXS_PORT": 27754,
  "HTTP_HOST": "0.0.0.0",
  "HTTP_PORT": 7380,
  "DXWEB_HOST": "0.0.0.0",
  "DXWEB_PORT": 7381,
  "DXWEB_SCHEME": "http",
  "MOJO_REVERSE_PROXY": 0,
  "DXWEB_WS_PER_IP_LIMIT": 12
}
```

Every key, default and scope is listed in
[`CONFIGURATION.md`](CONFIGURATION.md).

Inspect and validate it:

```bash
perl /spider/dxweb/dxwebctl config show
perl /spider/dxweb/dxwebctl config check
perl /spider/dxweb/dxwebctl config set DXWEB_WS_PER_IP_LIMIT=8
```

Restart the affected service after changing configuration.

---

## Cloudflare Turnstile

Turnstile is optional but recommended for public nodes. Create a widget at
Cloudflare, then either use the menu option `4` or write the key file:

```json
{
  "enabled": true,
  "site_key": "0x4AAAA...",
  "secret_key": "0x4AAAA..."
}
```

The path is set by `DXWEB_TURNSTILE_CONFIG`. The browser loads the challenge
only when Turnstile is enabled. Restrict the file:

```bash
sudo chmod 600 /etc/dxweb/turnstile.json
sudo chown sysop:spider /etc/dxweb/turnstile.json
```

The application treats a group- or world-readable key file as broken.

---

## Logs and health

```bash
perl /spider/dxweb/dxwebctl logs dxweb -f
perl /spider/dxweb/dxwebctl logs admin -f
curl -s http://127.0.0.1:7380/readyz
curl -s http://127.0.0.1:7381/readyz
```

`/healthz` reports process state, `/readyz` returns 200 only when the
DXSpider link is ready, and `/version.json` returns the running release.

---

## Updating

The recommended path is the guided upgrade helper:

```bash
curl -fsSL https://raw.githubusercontent.com/EA3CV/dxspider/mojo/upgrade.sh \
  -o /tmp/dxspider-upgrade.sh
sudo bash /tmp/dxspider-upgrade.sh
```

It snapshots the code and data, fast-forwards the branch, restarts dxspider,
DXWeb and DXWeb Admin, and verifies the endpoints. Rollback instructions are
printed after every run. See `docs/UPGRADE.md`.

Manual web update:

```bash
cd /spider
sudo systemctl stop dxweb.service dxweb-admin.service
sudo -iu sysop git pull --ff-only origin mojo
sudo perl dxweb/dxweb-manager.pl --action install --root /spider \
  --components both --mode direct --scheme http --apply
```

Code updates do not reload a running process. Restart the web services after
updating their files, and restart DXSpider after updating Perl modules such
as `perl/Web.pm`.

---

## Security notes

- Use HTTPS for any public login or administration.
- Keep the DXSpider IntMsg port bound to localhost.
- Do not expose the backend ports 7480 and 7481.
- Keep the admin application on a trusted network or behind an
  authenticating proxy.
- Review `README_DXWeb`, `INSTALL_DXWEB.en` and
  [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) before going live.
