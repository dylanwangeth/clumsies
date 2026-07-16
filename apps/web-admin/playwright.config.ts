import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  workers: 1,
  timeout: 60_000,
  expect: {
    timeout: 10_000,
  },
  reporter: process.env.CI ? "line" : "list",
  use: {
    ...devices["Desktop Chrome"],
    baseURL: "http://127.0.0.1:1423/admin/",
    channel: process.env.CI ? undefined : "chrome",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  webServer: [
    {
      command: "sh dev/web-admin-e2e-server.sh",
      cwd: "../..",
      url: "http://127.0.0.1:18090/api/v1/admin/health",
      reuseExistingServer: false,
      timeout: 300_000,
    },
    {
      command: "env VITE_CLUMSIES_SERVER_URL=http://127.0.0.1:18090 bun run dev:e2e",
      cwd: ".",
      url: "http://127.0.0.1:1423/admin/",
      reuseExistingServer: false,
      timeout: 60_000,
    },
  ],
});
