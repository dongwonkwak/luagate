import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ErrorAlert } from "./ErrorAlert";

describe("ErrorAlert", () => {
  it("renders an accessible dismiss button name when dismissible", () => {
    render(<ErrorAlert message="Something went wrong" onDismiss={vi.fn()} />);

    expect(screen.getByRole("button", { name: "Dismiss error" })).toBeTruthy();
  });
});
