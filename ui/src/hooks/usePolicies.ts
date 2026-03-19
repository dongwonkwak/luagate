import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { getPolicies, putPolicies, apiClient } from "../api/client";
import type { ReloadResponse } from "../types/api";

export function usePolicies(enabled = true) {
  return useQuery({
    queryKey: ["policies"],
    queryFn: getPolicies,
    enabled,
  });
}

export function useUpdatePolicies() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ yaml, etag }: { yaml: string; etag: string }) =>
      putPolicies(yaml, etag),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["policies"] });
      void queryClient.invalidateQueries({ queryKey: ["health"] });
    },
  });
}

export function useReloadPolicies() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async () => {
      const { data } = await apiClient<ReloadResponse>("/v1/policies/reload", {
        method: "POST",
      });
      return data;
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["policies"] });
      void queryClient.invalidateQueries({ queryKey: ["health"] });
    },
  });
}
