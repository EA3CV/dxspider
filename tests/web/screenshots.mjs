#!/usr/bin/env node

// Generate the README screenshots from the real browser applications.
//
// Usage: node tests/web/screenshots.mjs
// Requires Playwright with Chromium installed. Writes docs/images/*.png.

import { spawn } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { chromium } from "playwright";

const port = 7398;
const base = `http://127.0.0.1:${port}`;
const outDir = new URL("../../docs/images/", import.meta.url);

const spots = [
  ["14074.0", "DL1ABC", "FT8 strong in central Europe", "M0TEST"],
  ["21025.0", "K1XYZ", "CW, good signal", "G4ABC"],
  ["28050.0", "JA1DEF", "FT8, long path open", "M0TEST"],
  ["18100.0", "VK2GHI", "RTTY contest", "G4ABC"],
  ["7074.0", "W4JKL", "FT8, weak but workable", "M0TEST"],
  ["10136.0", "ZS6MNO", "CW, QSB", "G4ABC"],
  ["24915.0", "PY2PQR", "SSB, 59", "M0TEST"],
  ["50150.0", "SV9STU", "6m Es opening", "G4ABC"],
  ["144300.0", "EA8VWX", "SSB via tropo", "M0TEST"],
  ["3505.0", "VE3YZA", "CW, aurora flutter", "G4ABC"],
];

const rbnSpots = [
  ["14021.3", "9A1A", "CW 24 dB", "RBN"],
  ["21012.0", "PJ4DX", "CW 18 dB", "RBN"],
  ["7032.1", "S50ABC", "CW 12 dB", "RBN"],
];

function cc11([freq, call, comment, spotter]) {
  return `CC11^${freq}^${call}^20261128^1425Z^${comment}^${spotter}^GB7TEST`;
}

async function startFixture() {
  const server = spawn(process.execPath, ["tests/web/fixture-server.mjs"], {
    env: { ...process.env, FIXTURE_PORT: String(port) },
    stdio: ["ignore", "pipe", "inherit"],
  });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("fixture server did not start")),
      5000
    );
    server.stdout.on("data", (chunk) => {
      if (String(chunk).includes("fixture listening")) {
        clearTimeout(timer);
        resolve();
      }
    });
    server.on("exit", (code) =>
      reject(new Error(`fixture server exited with ${code}`))
    );
  });
  return server;
}

async function dxweb(browser) {
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    colorScheme: "dark",
    deviceScaleFactor: 1,
  });
  const page = await context.newPage();
  let socket;

  await page.routeWebSocket("**/dxweb/ws", (ws) => {
    socket = ws;
    ws.onMessage((raw) => {
      const m = JSON.parse(raw);
      if (m.type === "auth") {
        ws.send(
          JSON.stringify({
            type: "auth",
            status: "ok",
            call: m.call,
            registered: true,
            password_used: true,
          })
        );
      }
    });
    setTimeout(
      () =>
        ws.send(
          JSON.stringify({
            type: "status",
            state: "ready",
            authenticated: false,
            node_call: "GB7TEST-2",
          })
        ),
      30
    );
  });

  await page.goto(`${base}/dxweb/`);
  await page.fill("#loginCall", "M0TEST");
  await page.locator("#loginSubmit").click();
  await page.waitForSelector("#loginButton:has-text('Logout')");

  await page.locator("#showRbn").check();
  for (const spot of spots) {
    socket.send(
      JSON.stringify({ type: "feed", feed: "human", payload: cc11(spot) })
    );
  }
  for (const spot of rbnSpots) {
    socket.send(
      JSON.stringify({ type: "feed", feed: "rbn", payload: cc11(spot) })
    );
  }

  await page.waitForFunction(
    () => document.querySelectorAll("#spotRows tr").length >= 13
  );
  await page.waitForTimeout(500);

  await mkdir(outDir, { recursive: true });
  await page.screenshot({
    path: new URL("dxweb-spots.png", outDir).pathname,
    fullPage: false,
  });

  // A second view: the visual filter editor with a few real rules.
  await page.locator('.tabs button[data-tab="filters"]').click();
  await page.locator("#filterLoad").click();
  socket.send(
    JSON.stringify({
      type: "command_result",
      status: "ok",
      final: true,
      messages: [
        "spots : spots",
        "filter1 accept call DL1ABC",
        "filter2 reject info RTTY",
        "filter3 accept call_dxcc 291",
      ],
    })
  );
  await page.waitForSelector(".vf-rule");
  await page.locator(".vf-rule button").first().click();
  await page.waitForTimeout(300);
  await page.screenshot({
    path: new URL("dxweb-filters.png", outDir).pathname,
    fullPage: false,
  });

  await context.close();
}

async function admin(browser) {
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    colorScheme: "dark",
    deviceScaleFactor: 1,
  });
  const page = await context.newPage();

  const overview = {
    snapshots: {
      status: {
        node: "GB7TEST-2",
        version: "1.57",
        build: "1042",
        git_branch: "mojo",
        git_version: "83bb149[r]",
        uptime_seconds: 864000,
        channels: 42,
        users: 38,
        nodes: 3,
        rbn: 1,
        web: 4,
        input_queue_max: 7,
        input_queue_total: 12,
        pending_connects: 0,
      },
      traffic: {
        transport: {
          bytes_in: 18446744,
          bytes_out: 9234567,
          lines_in: 192837,
          lines_out: 91827,
        },
        spots: { total: 54321, hf: 49876, vhf: 4445 },
      },
      self_health: { requests: 128, errors: 0 },
    },
    history: { window_coverage_seconds: 86400 },
    system: { admin_rss_bytes: 73400320 },
    snapshot_age_seconds: { status: 2, traffic: 2 },
  };

  await page.routeWebSocket("**/admin/ws", (ws) => {
    ws.onMessage((raw) => {
      const m = JSON.parse(raw);
      if (m.type === "auth") {
        ws.send(
          JSON.stringify({
            type: "auth",
            status: "ok",
            call: m.call,
            priv: 9,
            authenticated: true,
          })
        );
      }
      if (m.type === "metrics_policy_get") {
        ws.send(
          JSON.stringify({
            type: "metrics_policy_get_result",
            status: "ok",
            enabled: false,
          })
        );
      }
      if (m.type === "session_policy_get") {
        ws.send(
          JSON.stringify({
            type: "session_policy_get_result",
            status: "ok",
            policy: {},
          })
        );
      }
      if (m.type === "supervisor_overview") {
        ws.send(
          JSON.stringify({
            type: "supervisor_overview_result",
            status: "ok",
            result: overview,
          })
        );
      }
      if (m.type === "maintenance_snapshot") {
        ws.send(
          JSON.stringify({
            type: "maintenance_snapshot_result",
            status: "ok",
            result: {},
          })
        );
      }
    });
    setTimeout(
      () =>
        ws.send(
          JSON.stringify({
            type: "status",
            state: "ready",
            authenticated: false,
            node_call: "GB7TEST-2",
            enable_linux_terminal: false,
          })
        ),
      30
    );
  });

  await page.goto(`${base}/admin/`);
  await page.fill("#loginCall", "M0SYS");
  await page.fill("#loginPass", "secret");
  await page.locator("#loginSubmit").click();
  await page.waitForSelector("body.authenticated");

  await page.locator('[data-v2-target="supervision"]').click();
  await page.waitForSelector("#supervision.active");
  await page.waitForFunction(
    () =>
      document.querySelector("#supervisorStatus")?.textContent?.includes(
        "GB7TEST"
      ),
    { timeout: 5000 }
  );
  await page.waitForTimeout(600);

  await mkdir(outDir, { recursive: true });
  await page.screenshot({
    path: new URL("dxweb-admin-overview.png", outDir).pathname,
    fullPage: false,
  });

  await context.close();
}

const server = await startFixture();
const browser = await chromium.launch();
try {
  await dxweb(browser);
  await admin(browser);
  console.log("Screenshots written to docs/images/");
} finally {
  await browser.close();
  server.kill("SIGTERM");
}
