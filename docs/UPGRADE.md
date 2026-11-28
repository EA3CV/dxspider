# Upgrading DXSpider

`upgrade.sh` is a guided upgrade for a Git checkout of the `mojo` branch. It
is designed for sysops who do not want to remember the stop, backup, pull,
check and restart sequence.

```bash
curl -fsSL https://raw.githubusercontent.com/EA3CV/dxspider/mojo/upgrade.sh \
  -o /tmp/dxspider-upgrade.sh
sudo bash /tmp/dxspider-upgrade.sh
```

Always download the script first, read it, and keep a separate copy of your
data. The script creates its own snapshot, but that is not a substitute for
your normal backups.

---

## What it does

1. Finds the tree, owner, branch and remote.
2. Refuses to run on a dirty working tree or a detached HEAD.
3. Fetches the branch and compares revisions.
4. Shows the current and target versions, including DXWeb and DXWeb Admin.
5. Detects new variables in `perl/DXVars.pm.issue` that are missing from
   `local/DXVars.pm` and warns about them.
6. Stops DXWeb, DXWeb Admin and DXSpider.
7. Creates a snapshot with the code history, local configuration and
   `local_data`.
8. Fast-forwards the code, never merges or rebases local commits.
9. Runs a Perl syntax check on `perl/cluster.pl`.
10. Restarts the services, waits for the ports and checks the web endpoints.
11. Prints the previous and new versions, the snapshot path and the exact
    rollback command.

If the update or restart fails, services are restarted with the old code
where possible, and the rollback command is printed.

---

## Common commands

```bash
# Normal upgrade, interactive confirmation
sudo bash upgrade.sh

# Preflight only, no changes
sudo bash upgrade.sh --check

# Show the plan and commands, no changes
sudo bash upgrade.sh --dry-run

# Unattended, accept the plan
sudo bash upgrade.sh --yes

# Restart services without updating code
sudo bash upgrade.sh --restart

# Update code but leave services stopped
sudo bash upgrade.sh --no-restart

# Update code and re-run the web installer
sudo bash upgrade.sh --refresh-web

# Restore the latest snapshot
sudo bash upgrade.sh --rollback

# Restore a specific snapshot
sudo bash upgrade.sh --rollback-to /var/backups/dxspider/upgrade-20260101-120000
```

---

## Options

| Option | Meaning |
|---|---|
| `--dir DIR` | DXSpider tree, default `/spider` |
| `--branch NAME` | Branch to follow, default the current branch |
| `--repo URL` | Git remote, default the tree's `origin` |
| `--backup-dir DIR` | Snapshot directory, default `/var/backups/dxspider` |
| `--no-backup` | Skip the snapshot, not recommended |
| `--skip-web` | Do not restart the web services |
| `--refresh-web` | Re-run the web installer after the code update |
| `--no-restart` | Update code and check syntax, leave services stopped |
| `--restart` | Restart services without updating code |
| `--check` | Preflight only |
| `--dry-run` | Print the plan, change nothing |
| `--auto-rollback` | Restore the snapshot automatically if startup fails |
| `-y`, `--yes` | Accept the plan without asking |
| `--rollback` | Restore the latest snapshot |
| `--rollback-to DIR` | Restore a specific snapshot |

---

## The snapshot

Each upgrade creates a directory such as:

```
/var/backups/dxspider/upgrade-20260101-120000/
  code.bundle       Git bundle of the previous revision
  local.tar.gz      local/, local_cmd/, connect/
  data.tar.gz       local_data/, without debug logs and history
  metadata          Tree, revision, branch, remote, date and services
  upgrade.sh        A copy of the script used for this upgrade
```

The snapshot is created after the services stop, so SQLite files are
consistent. It is mode 0700 and owned by root.

`local_data` excludes `local_data/debug`, `*.log`, `dxhistory.db*` and
`local_data/badlist-backups`. The user database, registration state, bad
lists and configuration are included.

Rollback:

```bash
sudo bash /var/backups/dxspider/upgrade-.../upgrade.sh \
  --rollback-to /var/backups/dxspider/upgrade-...
```

Rollback stops services, resets tracked files to the previous revision,
restores `local/` and `local_data/`, restarts services and verifies them.
It does not delete untracked files outside the snapshot. Read the prompt.

---

## Configuration changes

The upgrade script does not edit `local/DXVars.pm` or
`local/Listeners.pm`. If the new template contains variables that are
missing locally, it lists them.

To merge them:

1. Keep the snapshot.
2. Copy the new template:
   `cp perl/DXVars.pm.issue local/DXVars.pm.new`
3. Compare with `diff -u local/DXVars.pm local/DXVars.pm.new`.
4. Move the values you need into `local/DXVars.pm`.
5. Run `perl -c local/DXVars.pm`.
6. Restart DXSpider.

`Guide_DXS_EN` section 15.1 has the full procedure.

---

## Web services

By default, the script restarts DXWeb and DXWeb Admin if their units exist.
It does not rewrite their unit files. Use `--refresh-web` when a release
changes the web units or ports and you want the existing installer to plan
and apply the update.

If the web applications are behind Nginx, the script only restarts the
application services. Nginx is not touched.

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| `The tree has local changes` | Commit or stash them, or use the manual procedure |
| `Detached HEAD` | Use `--branch mojo` |
| `local branch has commits` | Resolve or move the local commits before upgrading |
| `is not a Git checkout` | Use the manual procedure in `Guide_DXS_EN` section 14, or reinstall |
| `Mojolicious` or Perl check fails | Install the missing package and re-run |
| Service does not start | Read the snapshot path and run the rollback command |
| Web endpoint does not answer | Check the port, unit and `journalctl`, then roll back if needed |

Logs:

```bash
journalctl -u dxspider.service -n 100 --no-pager
journalctl -u dxweb.service -n 100 --no-pager
journalctl -u dxweb-admin.service -n 100 --no-pager
cat /var/log/dxspider-upgrade.log
```

---

## Manual fallback

The manual procedure remains the reference:

1. Stop services.
2. Back up the tree and data.
3. `git fetch` and `git merge --ff-only origin/mojo`.
4. Review `DXVars.pm` template changes.
5. Restart and verify.

See `Guide_DXS_EN` sections 12 to 16 for the full checklist, including
`DXVars.pm` migration and systemd handling.
