import type { Meta, StoryObj } from "@storybook/react-vite";
import { AuditLogPage } from "../pages/AuditLogPage";
import {
  AppProviders,
  mockFetch,
  jsonResponse,
  errorResponse,
} from "../stories/decorators";
import type { AuditResponse } from "../types/api";

const SAMPLE_ENTRIES: AuditResponse = {
  entries: [
    {
      timestamp: "2026-03-20T06:00:00Z",
      event: "reload_success",
      trigger: "admin_api",
      actor_ip: "172.29.0.1",
      previous_version: "abc12345",
      new_version: "def67890",
    },
    {
      timestamp: "2026-03-20T05:55:00Z",
      event: "policy_update_success",
      trigger: "admin_api",
      actor_ip: "172.29.0.1",
      previous_version: "xyz11111",
      new_version: "abc12345",
    },
    {
      timestamp: "2026-03-20T05:50:00Z",
      event: "reload_failure",
      trigger: "admin_api",
      actor_ip: "172.29.0.1",
      reason: "YAML parse error at line 15",
    },
    {
      timestamp: "2026-03-20T05:45:00Z",
      event: "auth_failure",
      trigger: "admin_api",
      actor_ip: "192.168.1.100",
    },
    {
      timestamp: "2026-03-20T05:40:00Z",
      event: "reload_success",
      trigger: "file_watch",
      actor_ip: "127.0.0.1",
      previous_version: "zzz99999",
      new_version: "xyz11111",
    },
  ],
  total: 5,
  offset: 0,
  limit: 50,
};

const meta: Meta<typeof AuditLogPage> = {
  title: "Pages/AuditLog",
  component: AuditLogPage,
  decorators: [
    (Story) => (
      <AppProviders>
        <div className="p-6">
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
type Story = StoryObj<typeof AuditLogPage>;

export const WithLogs: Story = {
  beforeEach: () => {
    return mockFetch({
      "/v1/audit": jsonResponse(SAMPLE_ENTRIES),
    });
  },
};

export const Empty: Story = {
  beforeEach: () => {
    return mockFetch({
      "/v1/audit": jsonResponse({
        entries: [],
        total: 0,
        offset: 0,
        limit: 50,
      }),
    });
  },
};

export const EndpointNotAvailable: Story = {
  beforeEach: () => {
    return mockFetch({
      "/v1/audit": errorResponse(404, "Not Found"),
    });
  },
};

export const Loading: Story = {
  beforeEach: () => {
    const original = window.fetch;
    window.fetch = () => new Promise(() => {});
    return () => {
      window.fetch = original;
    };
  },
};

export const Error: Story = {
  beforeEach: () => {
    return mockFetch({
      "/v1/audit": errorResponse(500, "Internal Server Error"),
    });
  },
};
