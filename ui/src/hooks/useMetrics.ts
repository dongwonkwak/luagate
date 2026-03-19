import { useQuery } from "@tanstack/react-query";
import { apiClient } from "../api/client";

export interface ParsedMetric {
  name: string;
  help: string;
  type: string;
  values: Array<{ labels: Record<string, string>; value: number }>;
}

function parsePrometheusText(text: string): ParsedMetric[] {
  const metrics: ParsedMetric[] = [];
  let current: ParsedMetric | null = null;

  for (const line of text.split("\n")) {
    if (line.startsWith("# HELP ")) {
      const rest = line.slice(7);
      const spaceIdx = rest.indexOf(" ");
      const name = rest.slice(0, spaceIdx);
      const help = rest.slice(spaceIdx + 1);
      current = { name, help, type: "", values: [] };
      metrics.push(current);
    } else if (line.startsWith("# TYPE ")) {
      const rest = line.slice(7);
      const spaceIdx = rest.indexOf(" ");
      const type = rest.slice(spaceIdx + 1);
      if (current) current.type = type;
    } else if (line && !line.startsWith("#") && current) {
      const match = line.match(/^([^{}\s]+)(?:\{([^}]*)\})?\s+(\S+)/);
      if (match) {
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
        current.values.push({ labels, value: parseFloat(match[3] ?? "0") });
      }
    }
  }
  return metrics;
}

async function fetchMetrics(): Promise<ParsedMetric[]> {
  const { data } = await apiClient<string>("/v1/../metrics", {
    headers: { Accept: "text/plain" },
  });
  return parsePrometheusText(typeof data === "string" ? data : "");
}

export function useMetrics(enabled = true) {
  return useQuery({
    queryKey: ["metrics"],
    queryFn: fetchMetrics,
    refetchInterval: 30_000,
    enabled,
  });
}
