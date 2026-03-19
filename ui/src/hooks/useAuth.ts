import { useState, useCallback } from "react";

const TOKEN_KEY = "luagate_admin_token";

export function useAuth() {
  const [token, setTokenState] = useState<string | null>(
    () => localStorage.getItem(TOKEN_KEY),
  );

  const login = useCallback((newToken: string) => {
    localStorage.setItem(TOKEN_KEY, newToken);
    setTokenState(newToken);
  }, []);

  const logout = useCallback(() => {
    localStorage.removeItem(TOKEN_KEY);
    setTokenState(null);
  }, []);

  return {
    token,
    isAuthenticated: token !== null,
    login,
    logout,
  };
}
