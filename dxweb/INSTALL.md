# Installation / operation

Target tree:

-   `/spider/dxweb`
-   `/spider/dxweb-admin`

Do not install into an unrelated test tree such as
`/root/test-sql-merge`.

## Preflight

Check current listeners:

``` sh
ss -ltnp | grep -E ':7380|:7381|:27754'
```

For each running web PID verify its working directory:

``` sh
readlink -f /proc/PID/cwd
tr '\0' ' ' </proc/PID/cmdline
echo
```

## Install

The closeout package is intended to be copied to the DXSpider host and
installed with the included installer. The installer creates backups of
files it replaces.

After installation, restart only the web processes affected by the
installed files. Do not restart DXSpider solely for frontend/backend
DXWeb changes unless `perl/Web.pm` itself has also been changed.

## Verification

``` sh
curl -sS http://127.0.0.1:7380/healthz
echo
curl -sS http://127.0.0.1:7381/healthz
echo
```

Expected healthy state includes:

-   `state: ready`
-   `error: null`

Then hard-refresh both browser pages and smoke-test Anonymous, User
Login, Admin Login/Logout and Registration.
