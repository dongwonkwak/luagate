import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { apiClient } from "../api/client";
import { ErrorAlert } from "../components/ErrorAlert";
import type { AuditResponse } from "../types/api";

const PAGE_SIZE = 50;

export function AuditLogPage() {
  const [offset, setOffset] = useState(0);

  const [endpointMissing, setEndpointMissing] = useState(false);

  const { data, isLoading, error } = useQuery({
    queryKey: ["audit", offset],
    queryFn: async () => {
      try {
        const { data } = await apiClient<AuditResponse>(
          `/v1/audit?offset=${offset}&limit=${PAGE_SIZE}`,
        );
        setEndpointMissing(false);
        return data;
      } catch (e) {
        // Audit endpoint may not be implemented yet (404)
        if (e instanceof Error && e.message.includes("404")) {
          setEndpointMissing(true);
          return { entries: [], total: 0, offset: 0, limit: PAGE_SIZE } as AuditResponse;
        }
        throw e;
      }
    },
    refetchInterval: 30_000,
  });

  if (isLoading) return <p className="text-gray-500">Loading audit logs...</p>;
  if (error) {
    return (
      <ErrorAlert title="Failed to load audit logs" message={error.message} />
    );
  }

  const entries = data?.entries ?? [];
  const total = data?.total ?? 0;
  const hasNext = offset + PAGE_SIZE < total;
  const hasPrev = offset > 0;

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <h2 className="text-2xl font-bold text-gray-900">Audit Logs</h2>
        <p className="text-sm text-gray-500">
          {total} total entries
        </p>
      </div>

      {endpointMissing && entries.length === 0 ? (
        <div className="rounded-md border border-yellow-200 bg-yellow-50 p-4 text-sm text-yellow-800">
          Audit log endpoint is not available yet. This feature will be enabled
          when the <code>/api/v1/audit</code> endpoint is implemented.
        </div>
      ) : entries.length === 0 ? (
        <p className="text-gray-500">No audit entries found.</p>
      ) : (
        <div className="overflow-hidden rounded-lg border border-gray-200 bg-white">
          <table className="min-w-full divide-y divide-gray-200">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500">
                  Time
                </th>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500">
                  Event
                </th>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500">
                  Trigger
                </th>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500">
                  Actor IP
                </th>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500">
                  Version
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {entries.map((entry, i) => (
                <tr key={`${entry.timestamp}-${i}`} className="hover:bg-gray-50">
                  <td className="whitespace-nowrap px-4 py-2 text-xs text-gray-600">
                    {new Date(entry.timestamp).toLocaleString()}
                  </td>
                  <td className="px-4 py-2 text-xs">
                    <span
                      className={`rounded px-1.5 py-0.5 ${
                        entry.event.includes("success")
                          ? "bg-green-100 text-green-800"
                          : entry.event.includes("failure")
                            ? "bg-red-100 text-red-800"
                            : "bg-gray-100 text-gray-800"
                      }`}
                    >
                      {entry.event}
                    </span>
                  </td>
                  <td className="px-4 py-2 text-xs text-gray-600">
                    {entry.trigger}
                  </td>
                  <td className="px-4 py-2 font-mono text-xs text-gray-600">
                    {entry.actor_ip}
                  </td>
                  <td className="px-4 py-2 font-mono text-xs text-gray-600">
                    {entry.new_version
                      ? `${entry.previous_version?.slice(0, 8)} → ${entry.new_version.slice(0, 8)}`
                      : "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Pagination */}
      {(hasPrev || hasNext) && (
        <div className="mt-4 flex justify-between">
          <button
            onClick={() => setOffset(Math.max(0, offset - PAGE_SIZE))}
            disabled={!hasPrev}
            className="rounded-md border border-gray-300 px-3 py-1 text-sm text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          >
            Previous
          </button>
          <span className="text-sm text-gray-500">
            {offset + 1}–{Math.min(offset + PAGE_SIZE, total)} of {total}
          </span>
          <button
            onClick={() => setOffset(offset + PAGE_SIZE)}
            disabled={!hasNext}
            className="rounded-md border border-gray-300 px-3 py-1 text-sm text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          >
            Next
          </button>
        </div>
      )}
    </div>
  );
}
