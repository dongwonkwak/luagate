import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PolicyEditorPage } from "./PolicyEditorPage";

vi.mock("@monaco-editor/react", () => ({
  default: ({
    value,
    onChange,
  }: {
    value: string;
    onChange: (value: string | undefined) => void;
  }) => (
    <textarea
      aria-label="Policy YAML Editor"
      value={value}
      onChange={(event) => onChange(event.target.value)}
    />
  ),
}));

const usePoliciesMock = vi.fn();
const updateMutateAsyncMock = vi.fn();
const reloadMutateAsyncMock = vi.fn();

vi.mock("../hooks/usePolicies", () => ({
  usePolicies: () => usePoliciesMock(),
  useUpdatePolicies: () => ({
    mutateAsync: updateMutateAsyncMock,
    isPending: false,
  }),
  useReloadPolicies: () => ({
    mutateAsync: reloadMutateAsyncMock,
    isPending: false,
  }),
}));

describe("PolicyEditorPage", () => {
  beforeEach(() => {
    usePoliciesMock.mockReset();
    updateMutateAsyncMock.mockReset();
    reloadMutateAsyncMock.mockReset();
  });

  it("preserves the original ETag while the editor has unsaved changes", async () => {
    let latestPolicy = {
      data: { yaml: "mode: enforce\n", etag: "etag-1" },
      isLoading: false,
      error: null,
    };

    usePoliciesMock.mockImplementation(() => latestPolicy);
    updateMutateAsyncMock.mockResolvedValue({ headers: new Headers() });

    const { rerender } = render(<PolicyEditorPage />);

    const editor = await screen.findByLabelText("Policy YAML Editor");
    fireEvent.change(editor, { target: { value: "mode: report\n" } });

    latestPolicy = {
      data: { yaml: "mode: monitor\n", etag: "etag-2" },
      isLoading: false,
      error: null,
    };
    rerender(<PolicyEditorPage />);

    expect(
      (screen.getByLabelText("Policy YAML Editor") as HTMLTextAreaElement)
        .value,
    ).toBe("mode: report\n");
    expect(screen.getByText("etag-1")).toBeTruthy();
    expect(screen.queryByText("etag-2")).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => {
      expect(updateMutateAsyncMock).toHaveBeenCalledWith({
        yaml: "mode: report\n",
        etag: "etag-1",
      });
    });
  });
});
