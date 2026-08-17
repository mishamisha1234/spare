import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

// Runs the Worker in the real workerd runtime with real Durable Objects, so
// the consistency guarantee the limits depend on is actually exercised rather
// than mocked away.
export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          kvNamespaces: ["LESSONS"],
        },
      },
    },
  },
});
