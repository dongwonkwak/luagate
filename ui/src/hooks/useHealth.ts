import { useQuery } from "@tanstack/react-query";
import type { HealthResponse } from "../types/api";

async function fetchHealth(): Promise<HealthResponse> {
  // /health is always at the server root, never under /api prefix
  const res = await fetch("/health");
  if (!res.ok) throw new Error(`Health check failed: ${res.status}`);
  return res.json() as Promise<HealthResponse>;
}

export function useHealth(enabled = true) {
  return useQuery({
    queryKey: ["health"],
    queryFn: fetchHealth,
    refetchInterval: 30_000,
    enabled,
  });
}
