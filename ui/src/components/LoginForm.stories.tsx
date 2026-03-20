import type { Meta, StoryObj } from "@storybook/react-vite";
import { userEvent, within } from "@storybook/test";
import { LoginPage } from "../pages/LoginPage";
import {
  AppProviders,
  mockFetch,
  jsonResponse,
  errorResponse,
} from "../stories/decorators";

const meta: Meta<typeof LoginPage> = {
  title: "Pages/Login",
  component: LoginPage,
  decorators: [
    (Story) => (
      <AppProviders>
        <Story />
      </AppProviders>
    ),
  ],
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;
type Story = StoryObj<typeof LoginPage>;

export const Initial: Story = {
  beforeEach: () => {
    localStorage.removeItem("luagate_admin_token");
    return mockFetch({
      "/v1/policies/version": jsonResponse({
        source_version: "abc123",
        active_http_version: "abc123",
        active_stream_version: "abc123",
        etag: "abc123",
      }),
    });
  },
};

export const InvalidToken: Story = {
  beforeEach: () => {
    localStorage.removeItem("luagate_admin_token");
    return mockFetch({
      "/v1/policies/version": errorResponse(401, "Invalid token"),
    });
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const input = canvas.getByLabelText("Bearer Token");
    await userEvent.type(input, "wrong-token");
    const button = canvas.getByRole("button", { name: /login/i });
    await userEvent.click(button);
  },
};

export const ServerError: Story = {
  beforeEach: () => {
    localStorage.removeItem("luagate_admin_token");
    return mockFetch({
      "/v1/policies/version": errorResponse(500, "Internal Server Error"),
    });
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const input = canvas.getByLabelText("Bearer Token");
    await userEvent.type(input, "any-token");
    const button = canvas.getByRole("button", { name: /login/i });
    await userEvent.click(button);
  },
};
