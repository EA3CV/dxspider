# DXWeb protocol and trust boundaries

## Technical connection

DXWeb connects to DXSpider through the `#WEB-n` mechanism. User and
Admin applications have independent technical connections.

The technical channel is transport, not an authenticated browser
identity.

Invariant:

`#WEB-n effective channel privilege = 0`

Persistent `#WEB-n` DXUser records may have no stored `priv` field. That
does not grant privilege.

## Roles

Normal web role: `dxweb`\
Administrative web role: `dxweb-admin`

The Admin role is a separate server-authorized path and must not be
selectable as a privilege escalation by normal browser data.

## Web User authentication

Authentication establishes identity. It does not copy the persistent
DXUser privilege into the normal Web actor.

Normal Web actor:

`effective priv = 0`

This remains true when the authenticated callsign belongs to a SYSOP.

## Anonymous receive mode

An unauthenticated browser may receive the public feed required by the
UI:

-   C/R spots;
-   ANN;
-   WWV;
-   WCY;
-   WX.

Anonymous browser-originated command, spot and announcement operations
remain prohibited. Registration request is the deliberate exception
because an anonymous visitor must be able to request registration.

## Admin authorization

Admin authentication is checked server-side against the real DXSpider
user and requires privilege \>= 9. Browser-provided privilege values are
never trusted.

## Backpressure

The web path must remain non-blocking with respect to DXSpider. Existing
bounded history/fanout queues, guarded WebSocket sends and slow-client
disconnection behaviour are part of this requirement and must not be
removed when extending the UI.
