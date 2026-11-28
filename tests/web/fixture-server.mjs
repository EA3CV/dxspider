#!/usr/bin/env node

// Minimal static fixture for the Playwright smoke tests.
//
// It serves the real browser files, stubs the JSON endpoints the pages call at
// startup, and leaves WebSockets to Playwright's routeWebSocket mock. It is not
// a DXWeb replacement and must never be exposed beyond localhost.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../..", import.meta.url));
const port = Number(process.env.FIXTURE_PORT || 7399);

const trees = {
  "/dxweb/": join(root, "dxweb/public"),
  "/admin/": join(root, "dxweb-admin/admin"),
};

const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
};

const dxwebVersion = (await readFile(join(root, "dxweb/VERSION"), "utf8")).trim();
const adminVersion = (
  await readFile(join(root, "dxweb-admin/VERSION"), "utf8")
).trim();

function json(res, body) {
  res.writeHead(200, { "content-type": mime[".json"], "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

function send(res, status, body, type = "text/plain; charset=utf-8") {
  res.writeHead(status, { "content-type": type, "cache-control": "no-store" });
  res.end(body);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "127.0.0.1"}`);
  const path = decodeURIComponent(url.pathname);

  if (req.method !== "GET" && req.method !== "HEAD") {
    return send(res, 405, "method not allowed");
  }

  for (const [prefix, base] of Object.entries(trees)) {
    if (!path.startsWith(prefix)) continue;
    const rest = path.slice(prefix.length);

    const stub = await stubs(prefix, rest, res);
    if (stub) return;

    const target = join(base, rest || "index.html");
    const safe = normalize(target);
    if (!safe.startsWith(base + sep) && safe !== base) {
      return send(res, 403, "forbidden");
    }
    try {
      const data = await readFile(safe);
      res.writeHead(200, {
        "content-type": mime[extname(safe)] || "application/octet-stream",
        "cache-control": "no-store",
      });
      res.end(req.method === "HEAD" ? undefined : data);
    } catch {
      send(res, 404, "not found");
    }
    return;
  }

  send(res, 404, "not found");
});

async function stubs(prefix, rest, res) {
  if (rest === "turnstile-config.json") {
    json(res, { enabled: false, site_key: "" });
    return true;
  }
  if (rest === "healthz" || rest === "readyz") {
    json(res, { type: "status", state: "ready", ready: true });
    return true;
  }
  if (rest === "version.json") {
    json(res, {
      name: prefix === "/dxweb/" ? "DXSpider Web" : "DXSpider Web Admin",
      version: prefix === "/dxweb/" ? dxwebVersion : adminVersion,
    });
    return true;
  }
  if (rest === "software-version.json") {
    json(res, { running: dxwebVersion });
    return true;
  }
  if (rest === "admin-version.json") {
    json(res, { name: "DXSpider Web Admin", version: adminVersion });
    return true;
  }
  if (rest === "software-versions.json") {
    json(res, {
      dxweb: { running: dxwebVersion, installed: dxwebVersion },
      admin: { running: adminVersion, installed: adminVersion },
    });
    return true;
  }
  if (rest === "update-status.json") {
    json(res, {
      status: "OK",
      checked_at: new Date().toISOString(),
      comparisons: {
        branch: { comparable: true, match: true },
        version: { comparable: true, match: true },
        build: { comparable: true, match: true },
        commit: { comparable: true, match: true },
      },
    });
    return true;
  }
  return false;
}

server.listen(port, "127.0.0.1", () => {
  console.log(`fixture listening on http://127.0.0.1:${port}`);
});

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
