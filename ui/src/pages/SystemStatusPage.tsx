import { useHealth } from "../hooks/useHealth";
import { useQuery } from "@tanstack/react-query";
import { apiClient } from "../api/client";
import { StatusBadge } from "../components/StatusBadge";
import { ErrorAlert } from "../components/ErrorAlert";
import type { PolicyVersionResponse } from "../types/api";

export function SystemStatusPage() {
  const health = useHealth();
  const versions = useQuery({
    queryKey: ["policyVersions"],
    queryFn: async () => {
      const { data } = await apiClient<PolicyVersionResponse>(
        "/v1/policies/version",
      );
      return data;
    },
    refetchInterval: 30_000,
  });

  if (health.isLoading) {
    return <p className="text-gray-500">Loading...</p>;
  }

  if (health.error) {
    return (
      <ErrorAlert title="Health Check Failed" message={health.error.message} />
    );
  }

  return (
    <div>
      <h2 className="mb-6 text-2xl font-bold text-gray-900">System Status</h2>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {/* Health Status */}
        <div className="rounded-lg border border-gray-200 bg-white p-4">
          <p className="text-sm text-gray-500">Health</p>
          <div className="mt-1">
            <StatusBadge status={health.data?.status ?? "unknown"} />
          </div>
        </div>

        {/* Policy Loaded At */}
        <div className="rounded-lg border border-gray-200 bg-white p-4">
          <p className="text-sm text-gray-500">Policy Loaded At</p>
          <p className="mt-1 text-sm font-semibold text-gray-900">
            {health.data?.policy_loaded_at
              ? new Date(health.data.policy_loaded_at).toLocaleString()
              : "—"}
          </p>
        </div>

        {/* FFI Watchdog */}
        <div className="rounded-lg border border-gray-200 bg-white p-4">
          <p className="text-sm text-gray-500">FFI Watchdog Timeouts</p>
          <p className="mt-1 text-xl font-semibold text-gray-900">
            {health.data?.ffi_watchdog_timeouts ?? "—"}
          </p>
        </div>
      </div>

      {/* Policy Versions */}
      <div className="mt-6 rounded-lg border border-gray-200 bg-white p-4">
        <h3 className="mb-3 text-lg font-medium text-gray-900">
          Policy Versions
        </h3>
        <dl className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <dt className="text-xs text-gray-500">Source Version</dt>
            <dd className="mt-0.5 truncate font-mono text-sm text-gray-900">
              {versions.data?.source_version ??
                health.data?.source_version ??
                "—"}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-gray-500">HTTP Active</dt>
            <dd className="mt-0.5 truncate font-mono text-sm text-gray-900">
              {versions.data?.active_http_version ??
                health.data?.active_http_version ??
                "—"}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-gray-500">Stream Active</dt>
            <dd className="mt-0.5 truncate font-mono text-sm text-gray-900">
              {versions.data?.active_stream_version ??
                health.data?.active_stream_version ??
                "—"}
            </dd>
          </div>
        </dl>
      </div>
    </div>
  );
}
