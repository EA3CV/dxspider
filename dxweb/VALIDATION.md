# DXWeb validation record --- 2026-09-16

This document records checks actually performed during the current
development session. It does not claim tests that were not run.

## Live connectivity

Observed User Web health:

-   TCP/7380 listening;
-   `state=ready`;
-   `error=null`;
-   independent assigned `#WEB-n`;
-   anonymous browser connected.

Observed Admin Web health:

-   TCP/7381 listening;
-   `state=ready`;
-   `error=null`;
-   independent assigned `#WEB-n`.

DXSpider IntMsg was observed listening on `127.0.0.1:27754`.

## Privilege separation

Live functional checks:

-   SYSOP account through **User Web**: privileged `stat/pc19list`
    returned `Not Allowed`.
-   SYSOP account through **Admin Web**: the privileged command
    executed.
-   privilege-0 account attempting **Admin Web**: rejected with
    `SYSOP privilege 9 is required.`

This demonstrates the intended separation between normal Web User
privilege and Admin authorization.

## Persistent #WEB records

SQLite `dxusers.db` records for `#WEB-1` and `#WEB-2` were inspected.
Their JSON data contained no persistent `priv` field. They were Type
`W`, Group `local`.

This is distinct from the effective live actor privilege and should not
be changed merely to make `stat/user` print a privilege.

## Anonymous receive

With `auth_ok=0`, User Web health counters increased for RBN and HUMAN
input while a browser WebSocket was connected, confirming server-side
feed delivery without Login.

## UI corrections validated during iteration

The following behaviours were implemented during the closeout series:

-   Anonymous indicator and anonymous RX mode.
-   Register available without Login.
-   C/R selectors remain usable anonymously.
-   unified opaque informational hover popups;
-   ANN Send popup moved above its Send area;
-   Admin permanent Login/Logout control;
-   Admin History/Search registration column corrections;
-   compact SSID display and range input support;
-   previous Admin session display cleared on successful Login;
-   redundant Operation Console button removed.

Final visual acceptance of the repository-upload snapshot should still
include a browser hard refresh and a short manual smoke test after
installation.
