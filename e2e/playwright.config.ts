import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  timeout: 30_000,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL:
      process.env.PLAYWRIGHT_BASE_URL || "http://localhost:9090/dashboard",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
});
