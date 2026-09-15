# DXSpider Web changes

## 2.5.0 — 2026-09-15

- Fixed repeated integrated login/logout/login failure caused by browser-side history replay reaching the WebSocket high-water buffer.
- Historical replay now yields/retries under browser-side backpressure without blocking or degrading DXSpider.
- Preserved the normal `auth -> user_del -> auth` protocol sequence; repeated login of the same CALL does not require restarting DXSpider, dxweb or the browser.
- Spots columns now remain fixed when displaying HUMAN, RBN or both feeds.
- `Source` is the first Spots column and `Comment` has the largest display area.
- HUMAN/RBN spot counters are cumulative and are no longer limited by the bounded in-memory spot list.
- Expanded `PROTOCOL-v2.md` with the implemented `#WEB` v2 interface: authentication, logout, command execution, spot and announcement submission, feeds, request IDs, ownership, errors and backpressure requirements.
- Updated validation and HTTP-surface checks for the integrated web interface.

## 2.0.0

- Mandatory browser login; no guest feed access.
- Integrated `dxweb` mode: DXSpider validates CALL/password.
- External `webcluster` mode remains externally authenticated; v1 HELLO remains accepted.
- Separate HUMAN/RBN, ANN, WWV, WCY and WX views/feeds.
- Filters and Console views execute normal DXSpider commands under the authenticated identity.
- Existing #WEB and browser backpressure/bounded-buffer protections extended to new feeds.
- HTTP health remains non-sensitive; feed/history fanout requires an authenticated WebSocket.
