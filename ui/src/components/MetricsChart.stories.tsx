import type { Meta, StoryObj } from "@storybook/react-vite";
import { MetricsDashboardPage } from "../pages/MetricsDashboardPage";
import {
  AppProviders,
  mockFetch,
  textResponse,
  errorResponse,
} from "../stories/decorators";

const SAMPLE_METRICS = `# HELP luagate_http_requests_total Total HTTP requests
# TYPE luagate_http_requests_total counter
luagate_http_requests_total{action="allow"} 15234
luagate_http_requests_total{action="deny"} 342
luagate_http_requests_total{action="error"} 5
# HELP luagate_active_connections Currently active connections
# TYPE luagate_active_connections gauge
luagate_active_connections{type="http"} 42
luagate_active_connections{type="stream"} 8
# HELP luagate_shared_dict_capacity_bytes Shared dict capacity
# TYPE luagate_shared_dict_capacity_bytes gauge
luagate_shared_dict_capacity_bytes{zone="luagate_policy"} 10485760
luagate_shared_dict_capacity_bytes{zone="luagate_metrics"} 5242880
# HELP luagate_shared_dict_free_bytes Shared dict free space
# TYPE luagate_shared_dict_free_bytes gauge
luagate_shared_dict_free_bytes{zone="luagate_policy"} 9437184
luagate_shared_dict_free_bytes{zone="luagate_metrics"} 4718592
`;

const meta: Meta<typeof MetricsDashboardPage> = {
  title: "Pages/MetricsDashboard",
  component: MetricsDashboardPage,
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
type Story = StoryObj<typeof MetricsDashboardPage>;

export const WithData: Story = {
  beforeEach: () => {
    return mockFetch({
      "/metrics": textResponse(SAMPLE_METRICS),
    });
  },
};

export const NoData: Story = {
  beforeEach: () => {
    return mockFetch({
      "/metrics": textResponse(""),
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
      "/metrics": errorResponse(500, "Metrics endpoint unavailable"),
    });
  },
};
