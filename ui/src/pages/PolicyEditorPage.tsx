import { useState, useEffect } from "react";
import Editor from "@monaco-editor/react";
import { usePolicies, useUpdatePolicies, useReloadPolicies } from "../hooks/usePolicies";
import { ErrorAlert } from "../components/ErrorAlert";

export function PolicyEditorPage() {
  const { data: policyData, isLoading, error: fetchError } = usePolicies();
  const updateMutation = useUpdatePolicies();
  const reloadMutation = useReloadPolicies();

  const [editorValue, setEditorValue] = useState("");
  const [currentEtag, setCurrentEtag] = useState<string | null>(null);
  const [serverYaml, setServerYaml] = useState("");
  const [message, setMessage] = useState<{
    type: "success" | "error";
    text: string;
  } | null>(null);

  const isDirty = serverYaml !== editorValue;

  useEffect(() => {
    if (policyData) {
      // Only overwrite editor if there are no unsaved changes
      if (!isDirty) {
        setEditorValue(policyData.yaml);
      }
      setServerYaml(policyData.yaml);
      setCurrentEtag(policyData.etag);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [policyData]);

  const handleSave = async () => {
    if (!currentEtag) {
      setMessage({ type: "error", text: "No ETag available. Refresh policies first." });
      return;
    }

    setMessage(null);

    try {
      const result = await updateMutation.mutateAsync({
        yaml: editorValue,
        etag: currentEtag,
      });
      // Immediately sync local state so editor is no longer dirty
      setServerYaml(editorValue);
      const newEtag = result.headers.get("ETag");
      if (newEtag) {
        setCurrentEtag(newEtag.replace(/"/g, ""));
      }
      setMessage({ type: "success", text: "Policy saved successfully." });
    } catch (err) {
      setMessage({
        type: "error",
        text: err instanceof Error ? err.message : "Failed to save policy",
      });
    }
  };

  const handleReload = async () => {
    if (isDirty) {
      const confirmed = window.confirm(
        "You have unsaved changes. Reloading will discard them. Continue?",
      );
      if (!confirmed) return;
      // User confirmed discard — reset editor to server state
      if (policyData) {
        setEditorValue(policyData.yaml);
        setServerYaml(policyData.yaml);
      }
    }
    setMessage(null);
    try {
      await reloadMutation.mutateAsync();
      setMessage({ type: "success", text: "Policy reloaded successfully." });
    } catch (err) {
      setMessage({
        type: "error",
        text: err instanceof Error ? err.message : "Failed to reload policy",
      });
    }
  };

  if (isLoading) return <p className="text-gray-500">Loading policies...</p>;

  if (fetchError) {
    return (
      <ErrorAlert
        title="Failed to load policies"
        message={fetchError.message}
      />
    );
  }

  return (
    <div className="flex h-full flex-col">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-2xl font-bold text-gray-900">Policy Editor</h2>
        <div className="flex gap-2">
          <button
            onClick={handleReload}
            disabled={reloadMutation.isPending}
            className="rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          >
            {reloadMutation.isPending ? "Reloading..." : "Reload"}
          </button>
          <button
            onClick={handleSave}
            disabled={!isDirty || updateMutation.isPending}
            className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {updateMutation.isPending ? "Saving..." : "Save"}
          </button>
        </div>
      </div>

      {message && (
        <div className="mb-4">
          {message.type === "error" ? (
            <ErrorAlert
              message={message.text}
              onDismiss={() => setMessage(null)}
            />
          ) : (
            <div className="rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-800">
              {message.text}
            </div>
          )}
        </div>
      )}

      {currentEtag && (
        <p className="mb-2 text-xs text-gray-400">
          ETag: <code>{currentEtag}</code>
          {isDirty && (
            <span className="ml-2 text-yellow-600">(unsaved changes)</span>
          )}
        </p>
      )}

      <div className="flex-1 overflow-hidden rounded-md border border-gray-200">
        <Editor
          height="100%"
          defaultLanguage="yaml"
          value={editorValue}
          onChange={(val) => setEditorValue(val ?? "")}
          options={{
            minimap: { enabled: false },
            fontSize: 13,
            lineNumbers: "on",
            scrollBeyondLastLine: false,
            wordWrap: "on",
            tabSize: 2,
          }}
        />
      </div>
    </div>
  );
}
