import { defineConfig, mergeConfig, type ViteUserConfig } from 'vitest/config';

/**
 * The shared Vitest configuration for every Connect package.
 *
 * Unlike oxlint and oxfmt, Vitest does not walk up for the nearest config - it
 * reads the one in the directory it runs from. So each package needs its own
 * file, and this is what those files extend.
 */
const BASE: ViteUserConfig = defineConfig({
  test: {
    // Both layouts, because packages differ: platform-pkg-dev keeps tests beside the
    // source, while a published package usually keeps them in test/.
    include: ['src/**/*.{test,spec}.ts', 'test/**/*.{test,spec}.ts'],
    exclude: ['**/node_modules/**', '**/dist/**', '**/cdk.out/**', '**/coverage/**'],

    // Explicit imports rather than globals: a test file that imports `expect`
    // is one the type checker and the editor can follow.
    globals: false,
    environment: 'node',

    // A test that hangs should fail the run rather than the CI job's clock.
    testTimeout: 10_000,
    hookTimeout: 10_000,
  },
});

/**
 * Builds a package's Vitest config from the shared base.
 *
 * Pass overrides to add to it - they are merged, so listing `include` here
 * replaces the base patterns rather than appending to them.
 */
export function devVitestConfig(overrides: ViteUserConfig = {}): ViteUserConfig {
  return mergeConfig(BASE, overrides);
}

export default devVitestConfig;
