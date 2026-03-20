/* eslint-disable react-refresh/only-export-components */
import type { ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";

/**
 * Shared Storybook decorator that provides QueryClient + MemoryRouter.
 * Each story gets a fresh QueryClient to avoid cache leaks between stories.
 */
export function AppProviders({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false, refetchOnWindowFocus: false },
    },
  });

  return (
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={["/dashboard"]}>{children}</MemoryRouter>
    </QueryClientProvider>
  );
}

/**
 * Install a fetch mock that intercepts requests matching URL patterns.
 * Call this in `play` or `beforeEach` to set up API mocks for stories.
 */
export function mockFetch(
  handlers: Record<string, () => Response>,
): () => void {
  const original = window.fetch;
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    for (const [pattern, handler] of Object.entries(handlers)) {
      if (url.includes(pattern)) {
        return Promise.resolve(handler());
      }
    }
    return original(url, init);
  };
  return () => {
    window.fetch = original;
  };
}

/** Helper to create a JSON Response */
export function jsonResponse(
  body: unknown,
  init?: ResponseInit,
): () => Response {
  return () =>
    new Response(JSON.stringify(body), {
      status: 200,
      headers: { "Content-Type": "application/json" },
      ...init,
    });
}

/** Helper to create a text Response (YAML, Prometheus, etc.) */
export function textResponse(
  body: string,
  contentType = "text/plain",
  init?: ResponseInit,
): () => Response {
  return () =>
    new Response(body, {
      status: 200,
      headers: { "Content-Type": contentType },
      ...init,
    });
}

/** Helper to create an error Response */
export function errorResponse(status: number, body: string): () => Response {
  return () =>
    new Response(JSON.stringify({ error: body }), {
      status,
      headers: { "Content-Type": "application/json" },
    });
}
