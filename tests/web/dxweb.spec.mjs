import { expect, test } from "@playwright/test";
import { readFileSync } from "node:fs";

const version = readFileSync(
  new URL("../../dxweb/VERSION", import.meta.url),
  "utf8"
).trim();

test("DXWeb loads, logs in and renders a human spot", async ({ page }) => {
  let socket;

  await page.routeWebSocket("**/dxweb/ws", (ws) => {
    socket = ws;
    ws.onMessage((raw) => {
      const message = JSON.parse(raw);
      if (message.type === "auth") {
        ws.send(
          JSON.stringify({
            type: "auth",
            status: "ok",
            call: message.call,
            registered: true,
            password_used: true,
          })
        );
      }
      if (message.type === "logout") {
        ws.send(JSON.stringify({ type: "logout_result", status: "ok" }));
      }
    });
    setTimeout(
      () =>
        ws.send(
          JSON.stringify({
            type: "status",
            state: "ready",
            authenticated: false,
            node_call: "GB7TEST",
          })
        ),
      25
    );
  });

  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));

  await page.goto("/dxweb/");
  await expect(page.locator("#nodeCall")).toHaveText("GB7TEST");
  await expect(page.locator("footer")).toContainText(version);
  await expect(page.locator("#loginDialog")).toBeVisible();

  await page.fill("#loginCall", "M0TEST");
  await page.locator("#loginSubmit").click();
  await expect(page.locator("#loginButton")).toContainText("Logout M0TEST");

  expect(socket).toBeTruthy();
  socket.send(
    JSON.stringify({
      type: "feed",
      feed: "human",
      payload:
        "CC11^14074.0^DL1ABC^20261128^1200Z^Test spot^M0TEST^GB7TEST",
    })
  );

  await expect(page.locator("#spotRows")).toContainText("DL1ABC");
  await expect(page.locator("#spotRows")).toContainText("Test spot");
  expect(pageErrors).toEqual([]);
});

test("DXWeb rejects an empty login instead of opening a socket command", async ({
  page,
}) => {
  await page.routeWebSocket("**/dxweb/ws", (ws) => {
    setTimeout(
      () =>
        ws.send(
          JSON.stringify({
            type: "status",
            state: "ready",
            authenticated: false,
            node_call: "GB7TEST",
          })
        ),
      25
    );
  });

  await page.goto("/dxweb/");
  await expect(page.locator("#loginDialog")).toBeVisible();
  await page.locator("#loginSubmit").click();
  await expect(page.locator("#loginDialog")).toBeVisible();
});
