import { defineConfig } from "vitest/config";

// Kampodine is a plain-JS CLI package — hermetic node-environment tests only
// (no network, no OCI, no ssh). Mirrors the contracts package vitest 4 setup.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
