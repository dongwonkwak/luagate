// ui/src/App.tsx — smoke test
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import App from "./App";

describe("App", () => {
  it("renders the dashboard heading", () => {
    render(<App />);
    expect(
      screen.getByRole("heading", { name: /LuaGate Dashboard/i }),
    ).toBeDefined();
  });
});
