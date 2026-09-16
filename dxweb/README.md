# DXWeb 0.7.0 --- current closeout snapshot

Date: 2026-09-16

This package closes the current DXWeb development phase before
repository upload. It documents the two deliberately separated web
applications:

-   **DXWeb User** --- normal/anonymous user interface, normally on
    TCP/7380.
-   **DXWeb Admin** --- SYSOP administration interface, normally on
    TCP/7381.

The technical DXSpider transport remains a `#WEB-n` connection. The
technical channel is not the browser user and must not acquire the
browser user's privilege.

## Security model

### Web User

There are three user states:

1.  **Anonymous**
    -   receives Spots C and R;
    -   may enable/disable C and R independently;
    -   may view received ANN, WWV, WCY and WX;
    -   may clear receive windows;
    -   may open **Register** and submit a registration request;
    -   cannot send spots or announcements, run commands, use Filters or
        Console;
    -   Login-only controls remain visible but disabled/attenuated and
        show an explanatory hover popup;
    -   the header displays `Anonymous` until Login succeeds.
2.  **Logged in without password**
    -   existing login semantics are retained;
    -   effective Web User privilege remains 0;
    -   access is governed by the existing DXSpider
        authentication/registration rules.
3.  **Logged in with password**
    -   existing registered/authenticated semantics are retained;
    -   a SYSOP logging into the normal User Web still has effective Web
        User privilege 0;
    -   privileged DXSpider commands are not inherited from the
        persistent DXUser privilege.

The Login dialog labels the password as applicable when the user is
registered.

### Web Admin

Admin is a separate security context:

-   Admin authentication requires a valid DXSpider user and SYSOP
    privilege **9 or higher**.
-   A non-SYSOP login is rejected with `SYSOP privilege 9 is required.`
-   The Admin transport is restricted to the local DXSpider side; the
    tested IntMsg listener is bound to `127.0.0.1`.
-   The Admin page has a permanent **Login / Logout** control. Pressing
    Esc closes the login dialog but does not remove the Login button.
-   A successful Admin Login clears content left from the previous
    browser session before fresh data is loaded.
-   The normal User Web and Admin Web use independent `#WEB-n`
    connections.

Do not expose the existing localhost IntMsg listener by simply changing
it to `0.0.0.0`. A future remote User Web transport must preserve the
local-only Admin boundary.

## User interface

User tabs/areas:

-   Spots: anonymous RX for C/R; C/R selectors and Clear remain active.
-   ANN / WWV / WCY / WX: anonymous reception and Clear; command/send
    controls require Login as appropriate.
-   Filters / Console: Login-only.
-   Register: available to Anonymous.
-   Informational hover popups use a common solid, readable visual
    treatment.
-   The ANN Send hint is placed above the Send area to avoid clipping.

## Registration

The registration SSID field accepts individual values and ranges:

-   `1,2,3,4,5`
-   `1-5`
-   mixed sequences such as `1-3,7,8,9`

Consecutive values are compacted for display (`1,2,3,4,5` becomes `1-5`)
but are expanded and treated internally as individual SSIDs. Valid SSIDs
remain 1..99.

## Admin Registration

Registration provides Pending, History and Search views plus the
existing accept/reject workflow.

History/Search columns are:

`ID | Callsign | SSIDs | Status | Name | Email | Requested | Resolved | By | Note`

Duplicate `By`/`Note` headers were removed. `Note` is displayed from the
registration record. Consecutive SSIDs are compacted for presentation.

## Operational notes

User Web: `7380`\
Admin Web: `7381`\
DXSpider IntMsg in the tested deployment: `127.0.0.1:27754`

Restarting either web application does **not** require restarting
DXSpider when only the web frontend/backend files in this package are
changed.

Always verify the actual process working directory with
`/proc/<pid>/cwd`; during development an old
`/root/test-sql-merge/dxweb` process was found serving 7380. The
intended production tree for this work is `/spider/dxweb` and
`/spider/dxweb-admin`.

See `ADMIN.md`, `PROTOCOL.md`, `VALIDATION.md`, `CHANGES.md` and
`INSTALL.md`.
