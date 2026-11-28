# DXSpider installer reference

`install.sh` installs a complete DXSpider node and, optionally, DXWeb and
DXWeb Admin. It is the supported quick path for Debian, Ubuntu and
Raspberry Pi OS. The manual procedure in `Guide_DXS_EN` remains the
reference for every step and for other distributions.

```bash
curl -fsSL https://raw.githubusercontent.com/EA3CV/dxspider/mojo/install.sh \
  -o /tmp/dxspider-install.sh
sudo bash /tmp/dxspider-install.sh
```

Always download the script first and read it before running it as root.
The one-liner exists for convenience, not to hide what happens.

---

## What it asks

1. **Components**
   - DXSpider only
   - DXSpider + DXWeb (default)
   - DXSpider + DXWeb Admin
   - DXSpider + DXWeb + DXWeb Admin

   The default is DXSpider + DXWeb. DXWeb Admin is opt-in because it
   exposes privileged maintenance and a terminal.
2. **Node identity**: node callsign, SYSOP callsign, name, QTH, Maidenhead
   locator, latitude, longitude, contact email.
3. **Listener**: address and port, default `0.0.0.0:7300`.
4. **Plan**: the script prints every path, user, component and service
   before it changes anything.

Nothing is written until the plan is confirmed.

---

## Options

### Components

| Option | Result |
|---|---|
| `--dxspider-only` | DXSpider only |
| `--with-web` | DXSpider and DXWeb |
| `--with-admin` | DXSpider and DXWeb Admin |
| `--all` | DXSpider, DXWeb and DXWeb Admin |

`--with-web --with-admin` is equivalent to `--all`.

### Node data

| Option | Meaning |
|---|---|
| `--call CALL` | Node callsign, for example `GB7ABC-2` |
| `--alias CALL` | SYSOP callsign, default is the base callsign |
| `--name NAME` | Operator name |
| `--qth TEXT` | QTH description |
| `--locator QRA` | Maidenhead locator |
| `--lat DEGREES` | Latitude, south negative |
| `--lon DEGREES` | Longitude, west negative |
| `--email ADDRESS` | Contact address |
| `--port PORT` | Telnet listener port, default `7300` |
| `--listen ADDRESS` | Listener address, default `0.0.0.0` |

### Paths and source

| Option | Meaning |
|---|---|
| `--dir DIR` | Install tree, default `/home/sysop/spider` |
| `--user USER` | Unix account, default `sysop` |
| `--group GROUP` | Unix group, default `spider` |
| `--repo URL` | Git repository to clone |
| `--branch NAME` | Branch, default `mojo` |
| `--source DIR` | Copy a local tree instead of cloning |

### Web

| Option | Meaning |
|---|---|
| `--web-mode direct` | The applications listen directly (default) |
| `--web-mode nginx` | Nginx terminates public access |
| `--web-scheme http` | Plain HTTP (default) |
| `--web-scheme https` | HTTPS, requires hostname, certificate and key |
| `--web-hostname NAME` | Public DNS name |
| `--web-cert FILE` | TLS certificate |
| `--web-key FILE` | TLS private key |

### Behaviour

| Option | Meaning |
|---|---|
| `--upgrade` | Update the code of an existing installation |
| `--no-deps` | Do not install system packages |
| `--no-service` | Do not create systemd units |
| `--no-start` | Create units but do not start them |
| `-y`, `--yes` | Accept the plan without asking |
| `--non-interactive` | Never prompt, requires `--call` |
| `--dry-run` | Print the plan and commands, change nothing |
| `-h`, `--help` | Usage |

---

## Examples

```bash
# Interactive, choose components and answer the questions
sudo bash install.sh

# Unattended DXSpider only
sudo bash install.sh --non-interactive --dxspider-only \
  --call GB7ABC-2 --alias GB7ABC --name "Club station" \
  --qth "Somewhere" --locator JO02AA --lat 52.0 --lon 0.0 \
  --email sysop@example.org --yes

# DXSpider with both web applications, direct HTTP
sudo bash install.sh --all --call GB7ABC-2 --email sysop@example.org --yes

# Behind Nginx with an existing certificate
sudo bash install.sh --all --web-mode nginx --web-scheme https \
  --web-hostname dx.example.org \
  --web-cert /etc/letsencrypt/live/dx.example.org/fullchain.pem \
  --web-key /etc/letsencrypt/live/dx.example.org/privkey.pem

# Update code, keep local configuration
sudo bash install.sh --upgrade

# Preview only
bash install.sh --dry-run --all --call GB7ABC-2
```

---

## What it does

1. Checks that it is running as root and that the target is not already in
   use. It refuses to overwrite an existing node.
2. Installs the packages listed in `Guide_DXS_EN` section 3 through
   `apt-get` on Debian-like systems.
3. Creates the `spider` group and the `sysop` account if missing.
4. Clones the selected branch into `--dir`, or copies `--source`.
5. Creates `/spider` as a symlink to the installation tree.
6. Creates `local/`, `local_cmd/` and `local_data/`.
7. Copies `perl/DXVars.pm.issue` to `local/DXVars.pm` and applies the node
   identity. It copies `perl/Listeners.pm` and enables the chosen listener.
8. Runs `perl/create_sysop.pl` as `sysop`.
9. Writes `/etc/systemd/system/dxspider.service`, then enables and starts it.
10. Runs the DXWeb installer for the selected components. The web installer
    creates its own units and preserves any existing configuration.
11. Verifies services and prints the URLs.

The log is `/var/log/dxspider-install.log`, or `/tmp/dxspider-install.log`
when `/var/log` is not writable.

---

## After installation

```bash
systemctl status dxspider.service
journalctl -u dxspider.service -f

sudo -iu sysop
telnet 127.0.0.1 7300
```

At the cluster prompt:

```
sh/version
sh/cluster
sh/health
```

For the web services:

```bash
perl /spider/dxweb/dxwebctl status
perl /spider/dxweb/dxwebctl check
perl /spider/dxweb/dxwebctl logs dxweb -f
```

Read `Guide_DXS_EN` for peers, filters, registration, bad IP lists and
upgrades. Read `README_DXWeb` before exposing the web applications to the
internet.

---

## Upgrades

For a guided upgrade with a snapshot and rollback, use `upgrade.sh` and
read [`UPGRADE.md`](UPGRADE.md). The notes below describe the
`install.sh --upgrade` mode, which only updates the code.

`--upgrade` performs a code update only:

1. Stops `dxspider.service`.
2. Writes a timestamped backup next to the install tree.
3. Runs `git fetch` and `git merge --ff-only origin/<branch>` as the node
   user.
4. Reinstalls or updates the selected web components through the existing
   manager.

It does not edit `local/DXVars.pm` or `local/Listeners.pm`. If the template
gained new variables, follow section 15.1 of `Guide_DXS_EN` to merge them
by hand. Always take a data backup before upgrading.

For a node with no Git metadata, update the files manually and re-run
`install.sh --upgrade` only after checking the tree.

---

## Removal

The installer does not provide a destructive uninstall. To remove a test
node:

```bash
sudo systemctl disable --now dxspider.service
sudo systemctl disable --now dxweb.service dxweb-admin.service

# Keep the configuration and data if you may return.
sudo mv /home/sysop/spider /home/sysop/spider.removed
sudo rm /spider

sudo rm /etc/systemd/system/dxspider.service
sudo rm /etc/systemd/system/dxweb.service /etc/systemd/system/dxweb-admin.service
sudo systemctl daemon-reload
```

Remove the `sysop` user and `spider` group only when no other service uses
them. Review `/etc/nginx` if the web installer configured a proxy.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| `An installation already exists` | Use `--upgrade`, or move the old tree |
| `Mojolicious >= 7.26 is missing` | Re-run without `--no-deps`, or install the packages from the guide |
| `apt-get` missing | The distribution is not Debian-like; install the guide's packages manually |
| Service starts then stops | `journalctl -u dxspider.service -n 80` and check `local/DXVars.pm` |
| `create_sysop.pl` failed | Check ownership of `local_data`, and that the callsigns differ |
| Web ports unreachable | `ss -ltnp`, firewall, and `dxwebctl status --json` |
| HTTPS fails | Certificate and key paths, hostname coverage, `dxwebctl check` |

More web-specific symptoms are covered in
[`dxweb/TROUBLESHOOTING.md`](dxweb/TROUBLESHOOTING.md).
