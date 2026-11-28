import { expect, test } from "@playwright/test";

test("DXWeb Admin loads and authenticates a SYSOP over the mocked link", async ({
  page,
}) => {
  await page.routeWebSocket("**/admin/ws", (ws) => {
    ws.onMessage((raw) => {
      const message = JSON.parse(raw);
      if (message.type === "auth") {
        ws.send(
          JSON.stringify({
            type: "auth",
            status: "ok",
            call: message.call,
            priv: 9,
            authenticated: true,
          })
        );
      }
      if (message.type === "metrics_policy_get") {
        ws.send(
          JSON.stringify({
            type: "metrics_policy_get_result",
            status: "ok",
            enabled: false,
          })
        );
      }
      if (message.type === "session_policy_get") {
        ws.send(
          JSON.stringify({
            type: "session_policy_get_result",
            status: "ok",
            policy: {},
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
            node_call: "GB7TEST",
            enable_linux_terminal: false,
          })
        ),
      25
    );
  });

  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));

  await page.goto("/admin/");
  await expect(page.locator("#nodeCall")).toHaveText("GB7TEST");
  await expect(page.locator("#loginDialog")).toBeVisible();

  await page.fill("#loginCall", "M0SYS");
  await page.fill("#loginPass", "secret");
  await page.locator("#loginSubmit").click();

  await expect(page.locator("body")).toHaveClass(/authenticated/);
  await expect(page.locator("#loginButton")).toContainText("Logout M0SYS");
  await expect(page.locator("#loginDialog")).not.toBeVisible();
  expect(pageErrors).toEqual([]);
});
