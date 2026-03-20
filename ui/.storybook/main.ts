import type { StorybookConfig } from "@storybook/react-vite";
import { mergeConfig } from "vite";

const config: StorybookConfig = {
  stories: ["../src/**/*.mdx", "../src/**/*.stories.@(js|jsx|mjs|ts|tsx)"],
  addons: ["@storybook/addon-a11y", "@storybook/addon-docs"],
  framework: "@storybook/react-vite",
  viteFinal(config) {
    return mergeConfig(config, {
      // Override base path so Storybook doesn't inherit /dashboard/ from vite.config.ts
      base: "/",
    });
  },
};
export default config;
