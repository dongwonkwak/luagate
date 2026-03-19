import { useQuery } from "@tanstack/react-query";

export interface ParsedMetric {
  name: string;
  help: string;
  type: string;
  values: Array<{ labels: Record<string, string>; value: number }>;
}

function parsePrometheusText(text: string): ParsedMetric[] {
  const metrics: ParsedMetric[] = [];
  const metricMap = new Map<string, ParsedMetric>();
  let current: ParsedMetric | null = null;

  for (const line of text.split("\n")) {
    if (line.startsWith("# HELP ")) {
      const rest = line.slice(7);
      const spaceIdx = rest.indexOf(" ");
      const name = rest.slice(0, spaceIdx);
      const help = rest.slice(spaceIdx + 1);
      current = { name, help, type: "", values: [] };
      metrics.push(current);
      metricMap.set(name, current);
    } else if (line.startsWith("# TYPE ")) {
      const rest = line.slice(7);
      const spaceIdx = rest.indexOf(" ");
      const type = rest.slice(spaceIdx + 1);
      if (current) current.type = type;
    } else if (line && !line.startsWith("#")) {
      const match = line.match(/^([^{}\s]+)(?:\{([^}]*)\})?\s+(\S+)/);
      if (match) {
        const metricName = match[1] ?? "";
        const labels: Record<string, string> = {};
        if (match[2]) {
          for (const pair of match[2].split(",")) {
            const eqIdx = pair.indexOf("=");
            if (eqIdx === -1) continue;
            const k = pair.slice(0, eqIdx);
            const v = pair.slice(eqIdx + 1);
            labels[k] = v.replace(/"/g, "");
          }
        }

        // Find or create the metric entry by sample name
        const existing = metricMap.get(metricName);
        if (existing) {
          existing.values.push({ labels, value: parseFloat(match[3] ?? "0") });
        } else {
          const newMetric: ParsedMetric = {
            name: metricName,
            help: "",
            type: "",
            values: [{ labels, value: parseFloat(match[3] ?? "0") }],
          };
          metrics.push(newMetric);
          metricMap.set(metricName, newMetric);
        }
      }
    }
  }
  return metrics;
}

async function fetchMetrics(): Promise<ParsedMetric[]> {
  // /metrics is always at the server root, never under /api prefix
  const token = localStorage.getItem("luagate_admin_token");

  const res = await fetch("/metrics", {
    headers: {
      Accept: "text/plain",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
  });

  if (res.status === 401) {
    localStorage.removeItem("luagate_admin_token");
    window.location.href = "/dashboard/login";
    throw new Error("Unauthorized");
  }

  if (!res.ok) throw new Error(`Metrics fetch failed: ${res.status}`);
  const text = await res.text();
  return parsePrometheusText(text);
}

export function useMetrics(enabled = true) {
  return useQuery({
    queryKey: ["metrics"],
    queryFn: fetchMetrics,
    refetchInterval: 30_000,
    enabled,
  });
}
