import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { ErrorAlert } from "../components/ErrorAlert";

export function LoginPage() {
  const [tokenInput, setTokenInput] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const { login } = useAuth();
  const navigate = useNavigate();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (!tokenInput.trim()) {
      setError("Token is required");
      return;
    }

    setLoading(true);

    try {
      // Validate token by calling /health (no auth needed) then /api/v1/status (auth required)
      const baseUrl = import.meta.env.VITE_ADMIN_API_URL || "/api";
      const res = await fetch(`${baseUrl}/v1/status`, {
        headers: { Authorization: `Bearer ${tokenInput.trim()}` },
      });

      if (res.status === 401) {
        setError("Invalid token. Please check your Admin API token.");
        return;
      }

      if (!res.ok) {
        setError(`Server error: ${res.status} ${res.statusText}`);
        return;
      }

      login(tokenInput.trim());
      navigate("/dashboard");
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Failed to connect to server",
      );
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-gray-50">
      <div className="w-full max-w-md rounded-lg bg-white p-8 shadow-md">
        <h1 className="mb-2 text-2xl font-bold text-gray-900">LuaGate</h1>
        <p className="mb-6 text-sm text-gray-500">
          Enter your Admin API token to access the dashboard.
        </p>

        {error && (
          <div className="mb-4">
            <ErrorAlert message={error} onDismiss={() => setError(null)} />
          </div>
        )}

        <form onSubmit={handleSubmit}>
          <label
            htmlFor="token"
            className="block text-sm font-medium text-gray-700"
          >
            Bearer Token
          </label>
          <input
            id="token"
            type="password"
            value={tokenInput}
            onChange={(e) => setTokenInput(e.target.value)}
            placeholder="Enter LUAGATE_ADMIN_TOKEN"
            className="mt-1 block w-full rounded-md border border-gray-300 px-3 py-2 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
            autoFocus
          />

          <button
            type="submit"
            disabled={loading}
            className="mt-4 w-full rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {loading ? "Connecting..." : "Login"}
          </button>
        </form>
      </div>
    </div>
  );
}
