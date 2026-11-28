import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/web",
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: true,
  reporter: process.env.CI ? [["github"], ["line"]] : [["list"]],
  use: {
    baseURL: "http://127.0.0.1:7399",
    trace: "on-first-retry",
  },
  webServer: {
    command: "node tests/web/fixture-server.mjs",
    url: "http://127.0.0.1:7399/dxweb/healthz",
    reuseExistingServer: !process.env.CI,
    timeout: 10_000,
  },
  projects: [{ name: "chromium", use: { browserName: "chromium" } }],
});
