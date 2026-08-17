import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Runs the Worker in the real workerd runtime with real Durable Objects, so the
// consistency guarantee the limits depend on is actually exercised rather than
// mocked away. Each test file gets isolated storage, which is what lets the
// daily-limit tests start from a fresh counter instead of depending on the order
// they happen to run in.
//
// A Vite plugin rather than `defineWorkersConfig` and `poolOptions.workers`:
// that entry point was removed, and the package no longer publishes a ./config
// subpath at all.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        // The cache binding. Declared here rather than pointing at a real
        // namespace ID, so tests never touch production data.
        kvNamespaces: ["LESSONS"],
      },
    }),
  ],
});
