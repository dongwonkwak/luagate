import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import { useMetrics, type ParsedMetric } from "../hooks/useMetrics";
import { ErrorAlert } from "../components/ErrorAlert";

function findMetric(
  metrics: ParsedMetric[],
  name: string,
): ParsedMetric | undefined {
  return metrics.find((m) => m.name === name);
}

function MetricCard({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="rounded-lg border border-gray-200 bg-white p-4">
      <h3 className="mb-3 text-sm font-medium text-gray-500">{title}</h3>
      {children}
    </div>
  );
}

export function MetricsDashboardPage() {
  const { data: metrics, isLoading, error } = useMetrics();

  if (isLoading) return <p className="text-gray-500">Loading metrics...</p>;
  if (error) {
    return <ErrorAlert title="Failed to load metrics" message={error.message} />;
  }
  if (!metrics || metrics.length === 0) {
    return <p className="text-gray-500">No metrics available.</p>;
  }

  // HTTP Requests chart data
  const httpRequests = findMetric(metrics, "luagate_http_requests_total");
  const requestsData =
    httpRequests?.values.map((v) => ({
      action: v.labels.action || "unknown",
      count: v.value,
    })) ?? [];

  // Active connections
  const connections = findMetric(metrics, "luagate_active_connections");
  const connectionsData =
    connections?.values.map((v) => ({
      type: v.labels.type || "unknown",
      count: v.value,
    })) ?? [];

  // Shared dict usage
  const capacity = findMetric(metrics, "luagate_shared_dict_capacity_bytes");
  const free = findMetric(metrics, "luagate_shared_dict_free_bytes");
  const dictData =
    capacity?.values.map((v) => {
      const zone = v.labels.zone || "unknown";
      const cap = v.value;
      const freeVal =
        free?.values.find((f) => f.labels.zone === zone)?.value ?? 0;
      return {
        zone: zone.replace("luagate_", ""),
        used: cap - freeVal,
        free: freeVal,
      };
    }) ?? [];

  return (
    <div>
      <h2 className="mb-6 text-2xl font-bold text-gray-900">Metrics</h2>
      <p className="mb-4 text-xs text-gray-400">Auto-refresh every 30s</p>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        {/* HTTP Requests */}
        <MetricCard title="HTTP Requests Total">
          {requestsData.length > 0 ? (
            <ResponsiveContainer width="100%" height={200}>
              <BarChart data={requestsData}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="action" />
                <YAxis />
                <Tooltip />
                <Bar dataKey="count" fill="#3b82f6" />
              </BarChart>
            </ResponsiveContainer>
          ) : (
            <p className="text-sm text-gray-400">No data</p>
          )}
        </MetricCard>

        {/* Active Connections */}
        <MetricCard title="Active Connections">
          {connectionsData.length > 0 ? (
            <ResponsiveContainer width="100%" height={200}>
              <BarChart data={connectionsData}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="type" />
                <YAxis />
                <Tooltip />
                <Bar dataKey="count" fill="#10b981" />
              </BarChart>
            </ResponsiveContainer>
          ) : (
            <p className="text-sm text-gray-400">No data</p>
          )}
        </MetricCard>

        {/* Shared Dict Usage */}
        <MetricCard title="Shared Dict Memory">
          {dictData.length > 0 ? (
            <ResponsiveContainer width="100%" height={200}>
              <BarChart data={dictData}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="zone" />
                <YAxis />
                <Tooltip />
                <Bar dataKey="used" stackId="a" fill="#f59e0b" />
                <Bar dataKey="free" stackId="a" fill="#d1d5db" />
              </BarChart>
            </ResponsiveContainer>
          ) : (
            <p className="text-sm text-gray-400">No data</p>
          )}
        </MetricCard>

        {/* Raw Metrics Table */}
        <MetricCard title="All Metrics">
          <div className="max-h-[200px] overflow-y-auto">
            <table className="w-full text-left text-xs">
              <thead>
                <tr className="border-b border-gray-100">
                  <th className="pb-1 font-medium text-gray-500">Metric</th>
                  <th className="pb-1 font-medium text-gray-500">Type</th>
                  <th className="pb-1 text-right font-medium text-gray-500">
                    Values
                  </th>
                </tr>
              </thead>
              <tbody>
                {metrics.map((m) => (
                  <tr key={m.name} className="border-b border-gray-50">
                    <td className="py-1 font-mono">{m.name}</td>
                    <td className="py-1 text-gray-500">{m.type}</td>
                    <td className="py-1 text-right">{m.values.length}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </MetricCard>
      </div>
    </div>
  );
}
