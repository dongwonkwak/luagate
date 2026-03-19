import { useQuery } from "@tanstack/react-query";
import type { HealthResponse } from "../types/api";

const HEALTH_URL = import.meta.env.VITE_ADMIN_API_URL
  ? `${import.meta.env.VITE_ADMIN_API_URL}/health`
  : "/health";

async function fetchHealth(): Promise<HealthResponse> {
  const res = await fetch(HEALTH_URL);
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
