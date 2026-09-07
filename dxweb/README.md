# dxweb 1.7.0 — RX-only HUMAN/RBN

`dxweb` is the minimal read-only web client for the DXSpider `#WEB-n` technical
connection. It receives the global HUMAN and RBN feeds from DXSpider and fans
them out to browser WebSocket clients.

The directory is self-contained as the web application and is intended to live
inside the DXSpider checkout as:

    /spider/dxweb/

## DXSpider prerequisite

The DXSpider revision containing this directory must already contain the
compatible `perl/Web.pm` implementation for the `#WEB-n` webcluster role and
its DXSpider-side backpressure protection. That DXSpider change belongs in the
repository itself.

There is therefore **no Web.pm prepare/install/rollback step in dxweb**.
Do not copy or patch `Web.pm` when starting this application.

## Requirements

- Perl
- Mojolicious
- A running compatible DXSpider node
- DXSpider `#WEB` listener reachable from dxweb

Defaults:

    DXSpider: 127.0.0.1:27754
    HTTP:     0.0.0.0:8080
    feeds:    HUMAN=on, RBN=on

## Start

From the checkout:

    cd /spider/dxweb
    ./start.sh

`start.sh` runs in the foreground. Stop it with Ctrl-C or terminate the process
from the service/supervisor used by the deployment.

Do **not** set `WS_HIGH_WATER` for normal operation. Its default is 65536 bytes
(64 KiB). Smaller values such as 4096 or 256 were used only for controlled
stress tests.

## Check status

    curl -s http://127.0.0.1:8080/healthz | python3 -m json.tool

A normal connected instance reports, among other fields:

    "state": "ready"
    "web_call": "#WEB-n"
    "feeds": { "human": true, "rbn": true }

Open the web interface at port 8080. If the service is on a remote host, expose
it according to the deployment policy (for example through an SSH tunnel or a
reverse proxy); dxweb itself does not require public exposure.

## Optional environment

The normal defaults need no environment variables. Supported overrides include:

    DXS_HOST
    DXS_PORT
    HTTP_PORT
    FEED_HUMAN
    FEED_RBN
    RECONNECT_SEC
    MAX_INPUT_BYTES
    MAX_HISTORY
    MAX_HISTORY_BYTES
    MAX_FANOUT_ITEMS
    MAX_FANOUT_BYTES
    WS_HIGH_WATER
    REPLAY_BATCH
    FANOUT_BATCH

Example using a different HTTP port:

    HTTP_PORT=8081 ./start.sh

## Read-only and overload behaviour

The browser side is deliberately RX-only. Incoming browser WebSocket messages
are ignored and HTTP POST/PUT/PATCH/DELETE requests return 405. The application
does not expose browser-originated SPOT, ANNOUNCE, TALK or raw DXSpider command
paths.

Application-owned input, history and fanout queues are bounded. Slow browser
clients are disposable: overload must result in web data loss/client disconnect
rather than allowing a browser to pressure DXSpider.

## Utilities

Diagnostic/test utilities are under `tools/`. They are not required to start
or operate dxweb.
