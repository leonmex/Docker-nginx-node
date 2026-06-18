import { config as loadEnv } from 'dotenv';
import tsconfigPaths from 'vite-tsconfig-paths';
import { defineConfig } from 'vitest/config';

// Test-infra only: make the project-root .env available to integration tests.
// Production code never reads a .env file by path (see src/config.ts).
loadEnv({ path: '../.env' });

export default defineConfig({
  plugins: [tsconfigPaths()],
  test: {
    environment: 'node',
    include: ['test/**/*.test.ts'],
    // Integration tests skip themselves when Postgres/Redis are unreachable.
    testTimeout: 15000,
  },
});
