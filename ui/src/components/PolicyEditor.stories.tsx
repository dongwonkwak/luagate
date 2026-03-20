import type { Meta, StoryObj } from "@storybook/react-vite";
import { PolicyEditorPage } from "../pages/PolicyEditorPage";
import {
  AppProviders,
  mockFetch,
  textResponse,
  errorResponse,
} from "../stories/decorators";

const SAMPLE_YAML = `global:
  default_action: deny

rules:
  - id: allow-health
    scope:
      path: /health
      method: GET
    priority: 1
    action: allow

  - id: allow-api
    scope:
      path: /api/v1/*
    priority: 10
    action: allow
`;

const meta: Meta<typeof PolicyEditorPage> = {
  title: "Pages/PolicyEditor",
  component: PolicyEditorPage,
  decorators: [
    (Story) => (
      <AppProviders>
        <div className="h-[600px] p-6">
          <Story />
        </div>
      </AppProviders>
    ),
  ],
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;
type Story = StoryObj<typeof PolicyEditorPage>;

export const Default: Story = {
  beforeEach: () => {
    // Force plain textarea editor in Storybook (Monaco requires web worker)
    (
      window as typeof window & {
        __LUAGATE_FORCE_PLAIN_EDITOR__?: boolean;
      }
    ).__LUAGATE_FORCE_PLAIN_EDITOR__ = true;

    return mockFetch({
      "/v1/policies": textResponse(SAMPLE_YAML, "application/x-yaml", {
        headers: {
          "Content-Type": "application/x-yaml",
          ETag: '"abc123"',
        },
      }),
    });
  },
};

export const Empty: Story = {
  beforeEach: () => {
    (
      window as typeof window & {
        __LUAGATE_FORCE_PLAIN_EDITOR__?: boolean;
      }
    ).__LUAGATE_FORCE_PLAIN_EDITOR__ = true;

    return mockFetch({
      "/v1/policies": textResponse("", "application/x-yaml", {
        headers: {
          "Content-Type": "application/x-yaml",
          ETag: '"empty"',
        },
      }),
    });
  },
};

export const Loading: Story = {
  beforeEach: () => {
    (
      window as typeof window & {
        __LUAGATE_FORCE_PLAIN_EDITOR__?: boolean;
      }
    ).__LUAGATE_FORCE_PLAIN_EDITOR__ = true;

    // Never-resolving fetch to keep loading state
    const original = window.fetch;
    window.fetch = () => new Promise(() => {});
    return () => {
      window.fetch = original;
    };
  },
};

export const Error: Story = {
  beforeEach: () => {
    (
      window as typeof window & {
        __LUAGATE_FORCE_PLAIN_EDITOR__?: boolean;
      }
    ).__LUAGATE_FORCE_PLAIN_EDITOR__ = true;

    return mockFetch({
      "/v1/policies": errorResponse(500, "Internal Server Error"),
    });
  },
};
