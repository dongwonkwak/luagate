import { useHealth } from "../hooks/useHealth";
import { useQuery } from "@tanstack/react-query";
import { apiClient } from "../api/client";
import { StatusBadge } from "../components/StatusBadge";
import { ErrorAlert } from "../components/ErrorAlert";
import type { StatusResponse } from "../types/api";

function formatUptime(seconds: number): string {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

export function SystemStatusPage() {
  const health = useHealth();
  const status = useQuery({
    queryKey: ["status"],
    queryFn: async () => {
      const { data } = await apiClient<StatusResponse>("/v1/status");
      return data;
    },
    refetchInterval: 30_000,
  });

  if (health.isLoading || status.isLoading) {
    return <p className="text-gray-500">Loading...</p>;
  }

  if (health.error) {
    return (
      <ErrorAlert
        title="Health Check Failed"
        message={health.error.message}
      />
    );
  }

  return (
    <div>
      <h2 className="mb-6 text-2xl font-bold text-gray-900">System Status</h2>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {/* Health Status */}
        <div className="rounded-lg border border-gray-200 bg-white p-4">
          <p className="text-sm text-gray-500">Health</p>
          <div className="mt-1">
            <StatusBadge status={health.data?.status ?? "unknown"} />
          </div>
        </div>

        {/* Uptime */}
        <div className="rounded-lg border border-gray-200 bg-white p-4">
          <p className="text-sm text-gray-500">Uptime</p>
          <p className="mt-1 text-xl font-semibold text-gray-900">
            {status.data ? formatUptime(status.data.uptime_seconds) : "—"}
          </p>
        </div>

        {/* Workers */}
        <div className="rounded-lg border border-gray-200 bg-white p-4">
          <p className="text-sm text-gray-500">Workers</p>
          <p className="mt-1 text-xl font-semibold text-gray-900">
            {status.data?.worker_count ?? "—"}
          </p>
        </div>

        {/* Version */}
        <div className="rounded-lg border border-gray-200 bg-white p-4">
          <p className="text-sm text-gray-500">Version</p>
          <p className="mt-1 text-xl font-semibold text-gray-900">
            {status.data?.luagate_version ?? "—"}
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
              {health.data?.source_version ?? "—"}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-gray-500">HTTP Active</dt>
            <dd className="mt-0.5 truncate font-mono text-sm text-gray-900">
              {health.data?.active_http_version ?? "—"}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-gray-500">Stream Active</dt>
            <dd className="mt-0.5 truncate font-mono text-sm text-gray-900">
              {health.data?.active_stream_version ?? "—"}
            </dd>
          </div>
        </dl>
      </div>

      {/* Last Reload */}
      <div className="mt-4 rounded-lg border border-gray-200 bg-white p-4">
        <h3 className="mb-3 text-lg font-medium text-gray-900">Last Reload</h3>
        <dl className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div>
            <dt className="text-xs text-gray-500">Time</dt>
            <dd className="mt-0.5 text-sm text-gray-900">
              {status.data?.last_reload_at ?? "—"}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-gray-500">Status</dt>
            <dd className="mt-0.5 text-sm text-gray-900">
              {status.data?.last_reload_status ?? "—"}
            </dd>
          </div>
        </dl>
      </div>
    </div>
  );
}
