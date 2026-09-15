# DXSpider Web 2.5.0

`dxweb` is the DXSpider-integrated web client. It uses one technical `#WEB-n`
connection to DXSpider and multiplexes authenticated browser users over it.

## Authentication model

There are deliberately two distinct `#WEB` modes.

* `role=dxweb`, `auth=dxspider`, protocol v2: every browser must provide a
  callsign. DXSpider validates the callsign/password using the same password
  rule used by `ExtMsg.pm`: password is required when `$passwdreq` is enabled
  or the existing DXUser has a password. No browser feed or command access is
  provided before DXS returns successful authentication.
* `role=webcluster`, `auth=external`: an external WebCluster remains responsible
  for authenticating its own users. DXSpider does not receive or validate those
  user passwords. Existing v1 WebCluster negotiation remains accepted.

Passwords are forwarded only in the integrated `auth` request and are never
stored in dxweb state or written to the browser history.

## Views

The browser provides separate views for HUMAN/RBN spots, ANN, WWV, WCY, WX,
filters and the DXSpider console. Filter and console operations are executed by
DXSpider's normal command resolver under the authenticated logical user. dxweb
does not implement a second command permission system.

## Feeds and overload protection

DXSpider exports X/R/N/V/Y/W feed frames for HUMAN/RBN/ANN/WWV/WCY/WX. Web.pm
normalises their payload to JSON after the IntMsg `|`. The existing bounded
backpressure policy applies to all these disposable feeds. dxweb also bounds
input, history, fanout and each browser's write buffer. Live traffic remains
bounded; historical replay is cooperative and yields while the browser socket
is busy, so replay cannot falsely disconnect a normal browser or apply pressure
to DXSpider.

## Start

From the repository root:

    cd dxweb
    ./start.sh

Default listener: `http://0.0.0.0:8080`
Default DXSpider IntMsg endpoint: `127.0.0.1:27754`

Optional environment variables include `DXS_HOST`, `DXS_PORT`,
`WS_HIGH_WATER`, `MAX_INPUT_BYTES`, `MAX_HISTORY`, `MAX_HISTORY_BYTES`,
`MAX_FANOUT_ITEMS` and `MAX_FANOUT_BYTES`.

The corresponding `perl/Web.pm` from this version must be installed in the
same DXSpider tree and DXSpider restarted before starting dxweb.

## Validation

On the target DXSpider host:

    perl -I/spider/local -I/spider/perl -c /spider/perl/Web.pm
    cd /spider/dxweb
    perl -c app.pl
    ./start.sh

Then verify:

    curl -s http://127.0.0.1:8080/healthz

Expected DXS state after negotiation is `ready`. Open the web page and test at
least: a user without password (when policy permits), a user with password,
wrong password rejection, HUMAN/RBN, ANN, WWV, WCY, WX and a harmless command
such as `show/version` or `show/dx 5`.

## Security notes

There is no guest mode. The HTTP `/healthz` endpoint exposes transport status
only; feed/history data is sent only to authenticated WebSocket clients.

For a public deployment, terminate TLS in front of dxweb. The integrated mode
uses the WebSocket peer address as the user's source IP; do not blindly trust
client-supplied forwarding headers.


## Release 2.5.0 (2026-09-15)

This release closes the integrated login/logout session bug caused by browser
history replay reaching the WebSocket high-water mark. Re-authentication of the
same CALL after `user_del` is supported without restarting DXSpider, dxweb or
the browser.

The Spots view now keeps stable columns for HUMAN, RBN and combined display,
places Source first, gives Comment the largest width, and maintains cumulative
HUMAN/RBN counters independently of the bounded in-memory/rendered spot list.

`PROTOCOL-v2.md` documents the complete implemented v2 surface needed by an
integrated web client: hello/authentication, user removal, command execution,
spot and announcement submission, feed configuration, ownership, response IDs,
errors and backpressure requirements.
