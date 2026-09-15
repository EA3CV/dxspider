# DXSpider #WEB protocol v2

DXSpider Web release: 2.5.0  
Document date: 2026-09-15

This document describes the `#WEB` protocol implemented by the current
`perl/Web.pm` and the `#WEB` channel creation path in `perl/cluster.pl`.
It is intended to be sufficient for implementing either an external
WebCluster or an integrated web front end such as `dxweb` without having
to infer the protocol from the UI code.

## 1. Scope and architecture

`#WEB` is a technical DXSpider channel carried over the local IntMsg
connection. A web service normally sits between DXSpider and browsers:

``` text
Browser
   |
   | HTTP / WebSocket (application-specific)
   v
dxweb / WebCluster
   |
   | IntMsg #WEB protocol
   v
DXSpider
   cluster.pl -> Web.pm
```

The browser-facing protocol is not defined here. This document defines
the DXSpider-facing `#WEB` protocol.

A client opens the IntMsg connection using the special call `#WEB`.
`cluster.pl` allocates the next free technical channel (`#WEB-1`,
`#WEB-2`, ...), creates a `Web` channel, rewrites the original
`A#WEB|...` frame to the assigned call, and sends:

``` text
C#WEB-1
```

The assigned `#WEB-n` call must then be used by the IntMsg transport
framing.

## 2. Negotiation and roles

Before negotiation the channel retains the pre-existing Web/CLI
behaviour. JSON protocol handling is enabled by a `hello`.

### 2.1 Integrated `dxweb`

Request:

``` json
{"type":"hello","role":"dxweb","auth":"dxspider","version":2}
```

Successful response:

``` json
{"type":"hello","role":"dxweb","auth":"dxspider","version":2,"status":"ok"}
```

For `role=dxweb`, protocol version 2 is required and authentication mode
is `dxspider`.

### 2.2 External WebCluster

Protocol v1 remains valid:

``` json
{"type":"hello","role":"webcluster","version":1}
```

Protocol v2 may be negotiated as:

``` json
{"type":"hello","role":"webcluster","auth":"external","version":2}
```

For `role=webcluster`, supported versions are 1 and 2 and authentication
mode is external.

An unsupported version produces a `hello` response with
`status:"error"`, `error:"unsupported_version"` and a `supported` array.

## 3. Request IDs and responses

After successful negotiation, every request operation must contain a
non-empty `id`. The client should allocate unique IDs and correlate
responses by `id`.

General response shape:

``` json
{
  "type":"response",
  "id":12,
  "status":"ok",
  "action":"command"
}
```

Errors use the same response type:

``` json
{
  "type":"response",
  "id":12,
  "status":"error",
  "action":"command",
  "error":"not_owned"
}
```

A request without an ID returns:

``` json
{"type":"response","status":"error","error":"missing_id"}
```

Invalid JSON returns:

``` json
{"type":"response","status":"error","error":"invalid_json"}
```

Unknown request types return `status:"error"` and
`error:"unknown_type"`.

`status:"rejected"` is distinct from `status:"error"`. `rejected` is
used by operations such as spot and announcement when the normal
DXSpider command handler processed the request but returned user-facing
text indicating that it was not accepted. That text is returned in
`messages`.

## 4. Integrated authentication (`role=dxweb`)

An integrated web front end must use `auth`, not `user_add`.

Request:

``` json
{
  "type":"auth",
  "id":1,
  "call":"EA3CV",
  "password":"secret",
  "ip":"192.0.2.10"
}
```

`call` is normalized and validated by DXSpider. `ip` is required, must
be a valid IP address and is checked against DXSpider's bad-IP handling.
The password may be omitted or empty when DXSpider does not require one.

DXSpider applies its own authentication semantics. A password is
required when the global password requirement is active or the existing
`DXUser` has a password. The web application must not decide privileges
itself.

Example successful response:

``` json
{
  "type":"response",
  "id":1,
  "status":"ok",
  "action":"auth",
  "call":"EA3CV",
  "ip":"192.0.2.10",
  "authenticated":1,
  "auth_source":"dxspider",
  "password_used":1,
  "priv":1,
  "registered":1
}
```

The actual `priv`, `registered` and `password_used` values are
determined by DXSpider.

Possible authentication/user-presence errors implemented by the current
code include:

-   `wrong_auth_mode`
-   `invalid_call`
-   `invalid_ip`
-   `bad_ip`
-   `locked_out`
-   `not_user`
-   `bad_password`
-   `already_owned`
-   `already_connected`
-   `too_many_connections`
-   `route_add_failed`

A successful authentication also creates the logical user's transient
route presence owned by that `#WEB-n` channel.

## 5. External authentication (`role=webcluster`)

An external WebCluster continues to authenticate its users itself and
then uses `user_add`. It asserts `authenticated:true`; the user's
DXSpider password is not sent to DXSpider through this operation.

Conceptual request:

``` json
{
  "type":"user_add",
  "id":20,
  "call":"EA3CV",
  "ip":"192.0.2.10",
  "authenticated":true
}
```

In integrated `dxweb` mode, direct `user_add` is rejected with
`use_auth`.

An external unauthenticated `user_add` is rejected with
`authentication_required`.

## 6. Logout / logical user removal

Both models remove a logical user owned by the `#WEB-n` channel with
`user_del`.

Request:

``` json
{"type":"user_del","id":2,"call":"EA3CV"}
```

Successful response:

``` json
{
  "type":"response",
  "id":2,
  "status":"ok",
  "action":"user_del",
  "call":"EA3CV"
}
```

`user_del` removes the logical route presence and deletes the call from
the channel's internal `web_users` ownership table.

Errors include `invalid_call` and `not_owned`.

For an integrated web application, the normal reusable session cycle is
therefore:

``` text
AUTH(call)
  -> commands / spot / ann
USER_DEL(call)
AUTH(same call)
  -> commands / spot / ann
USER_DEL(call)
```

No extra pre-auth cleanup is part of the protocol.

If the browser-facing WebSocket closes while a logical user is still
authenticated, the intermediary should release that logical user with
`user_del` when possible.

## 7. Command execution

Request:

``` json
{
  "type":"command",
  "id":3,
  "call":"EA3CV",
  "command":"show/dx"
}
```

or:

``` json
{
  "type":"command",
  "id":4,
  "call":"EA3CV",
  "command":"w"
}
```

The call must be owned by this `#WEB-n`, authenticated, and currently
present.

DXSpider creates a transient `Web::Actor` for that logical user and
passes the supplied command through the normal DXSpider command
resolver. The web layer does not maintain a separate command whitelist
and does not reimplement DXSpider privilege checks.

Example response:

``` json
{
  "type":"response",
  "id":3,
  "status":"ok",
  "action":"command",
  "call":"EA3CV",
  "messages":[
    "   7098.0 EC5BUH ..."
  ]
}
```

`messages` contains the user-facing output returned/captured from normal
DXSpider command execution.

Errors implemented for command actor resolution/execution include:

-   `invalid_call`
-   `not_owned`
-   `not_authenticated`
-   `not_present`
-   `user_not_found`
-   `not_user`
-   `invalid_ip`
-   `bad_arguments`
-   `internal_error`

## 8. Sending a DX spot

A web client does not need to synthesize the normal CLI line itself.
Protocol v2 provides `spot`.

Request:

``` json
{
  "type":"spot",
  "id":5,
  "call":"EA3CV",
  "freq":"14074.0",
  "dxcall":"G1TLH",
  "comment":"FT8"
}
```

`comment` is optional and may be empty. `freq`, `dxcall` and `comment`
must not contain CR, LF or NUL.

Internally `Web.pm` executes the normal DXSpider `dx` command as the
authenticated logical user. Existing DXSpider validation, filters and
command semantics therefore remain authoritative.

Accepted:

``` json
{
  "type":"response",
  "id":5,
  "status":"ok",
  "action":"spot",
  "call":"EA3CV",
  "result":"processed"
}
```

Rejected by normal DXSpider processing:

``` json
{
  "type":"response",
  "id":5,
  "status":"rejected",
  "action":"spot",
  "call":"EA3CV",
  "messages":["...DXSpider message..."]
}
```

Protocol/ownership errors use `status:"error"` and may include the actor
errors listed for commands, plus `bad_arguments` or `internal_error`.

## 9. Sending an announcement

Request:

``` json
{
  "type":"ann",
  "id":6,
  "call":"EA3CV",
  "scope":"local",
  "text":"Test announcement"
}
```

Supported scopes are:

-   `local` --- normal local announcement
-   `full` --- executes normal `announce FULL ...`
-   `sysop` --- executes normal `announce SYSOP ...`

If omitted, `scope` defaults to `local`.

Accepted:

``` json
{
  "type":"response",
  "id":6,
  "status":"ok",
  "action":"ann",
  "call":"EA3CV",
  "scope":"local",
  "result":"processed"
}
```

Rejected by normal DXSpider processing:

``` json
{
  "type":"response",
  "id":6,
  "status":"rejected",
  "action":"ann",
  "call":"EA3CV",
  "scope":"local",
  "messages":["...DXSpider message..."]
}
```

As with spots, normal DXSpider command semantics and privileges are
authoritative.

## 10. Feed configuration

A negotiated `#WEB-n` channel can independently enable or disable:

-   `human`
-   `rbn`
-   `ann`
-   `wwv`
-   `wcy`
-   `wx`

Request:

``` json
{
  "type":"feed",
  "id":7,
  "human":true,
  "rbn":true,
  "ann":true,
  "wwv":true,
  "wcy":true,
  "wx":true
}
```

Only fields present in the request are changed. Values must decode to
protocol boolean `0` or `1`.

Successful response returns the complete current feed state:

``` json
{
  "type":"response",
  "id":7,
  "status":"ok",
  "action":"feed",
  "human":1,
  "rbn":1,
  "ann":1,
  "wwv":1,
  "wcy":1,
  "wx":1
}
```

Invalid values return `bad_arguments` with the offending `field`.
`user_not_found` is returned if the technical channel has no associated
DXUser.

## 11. Feed transport

Feed data is sent using the existing IntMsg framing letter followed by
the assigned `#WEB-n` call and `|`. For negotiated WebCluster/dxweb
channels, the payload after `|` is JSON.

Mapping:

  Letter   Feed            JSON `type`
  -------- --------------- -------------
  `X`      Human DX spot   `spot`
  `R`      RBN spot        `rbn`
  `N`      Announcement    `ann`
  `V`      WWV             `wwv`
  `Y`      WCY             `wcy`
  `W`      WX              `wx`

Example conceptual frame:

``` text
X#WEB-1|{"type":"spot","payload":"..."}
```

The `payload` is the DXSpider feed payload; applications may parse it
for presentation, but the protocol wrapper itself does not redefine the
underlying DXSpider feed fields.

## 12. Ownership and security model

A logical call is owned by the `#WEB-n` channel that added/authenticated
it. Operations using a call that is not owned by that channel fail with
`not_owned`.

`command`, `spot` and `ann` additionally require the logical user to be
authenticated and present. They fail rather than silently borrowing
another session.

In `dxweb` mode DXSpider is the authentication authority. The
intermediary must not manufacture `priv`, `registered` or authentication
success.

In external WebCluster mode the external WebCluster remains the
authentication authority and uses `user_add`.

## 13. Backpressure and non-blocking requirements

The `#WEB` path is designed so a web client cannot make DXSpider's node
processing wait on a slow browser or slow WebCluster.

`Web.pm` configures a bounded output high-water mark. Disposable feed
traffic is dropped when the technical channel is saturated and resumes
after the buffer drains. Control/protocol output is not silently
accumulated without bound; if control output cannot be written safely,
the technical `#WEB-n` channel may be disconnected.

An intermediary such as `dxweb` must preserve this design:

-   DXSpider input handling must remain asynchronous.
-   Browser WebSockets must have bounded output queues.
-   A slow browser must never cause unbounded buffering toward DXSpider.
-   Historical/replay data maintained by the intermediary is optional
    catch-up traffic and must respect browser-side backpressure.
-   Replay should yield/retry when the browser socket is busy rather
    than treating a temporary replay backlog as a reason to block
    DXSpider.
-   Live feed/history storage should have explicit size/item bounds.

The browser-side history/replay mechanism is not part of the `#WEB` wire
protocol.

## 14. Recommended integrated `dxweb` sequence

A minimal integrated implementation can follow this sequence:

``` text
1. Connect to IntMsg as #WEB.
2. Receive C#WEB-n assignment and complete the normal technical-channel greeting.
3. Send hello:
     role=dxweb, auth=dxspider, version=2
4. Verify hello status=ok.
5. Send feed request and correlate its response by id.
6. Browser login:
     send auth(id, call, password, ip)
7. On auth status=ok:
     retain call/authenticated state in the intermediary.
8. Execute:
     command(id, call, command)
     spot(id, call, ...)
     ann(id, call, ...)
9. Browser logout:
     send user_del(id, call)
10. On user_del status=ok:
     clear intermediary authentication state.
11. A later login of the same call is a normal new auth request.
```

The intermediary should maintain a pending-request table keyed by
protocol `id` so responses are routed back to the correct
browser/client. A response should consume its pending entry exactly
once.

## 15. Implemented request types

The current `Web.pm` implements these negotiated request types:

  -----------------------------------------------------------------------
  Request                             Purpose
  ----------------------------------- -----------------------------------
  `auth`                              DXSpider-authenticated logical user
                                      login (`dxweb`)

  `user_add`                          externally authenticated logical
                                      user presence (`webcluster`)

  `user_del`                          logical user logout/removal

  `feed`                              configure feed switches

  `command`                           execute a normal DXSpider command

  `spot`                              submit a spot through normal `dx`
                                      command semantics

  `ann`                               submit an announcement through
                                      normal `announce` semantics
  -----------------------------------------------------------------------

This table is deliberately limited to operations present in the current
implementation.
