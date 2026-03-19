import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { useAuth } from "./hooks/useAuth";
import { Layout } from "./components/Layout";
import { LoginPage } from "./pages/LoginPage";
import { SystemStatusPage } from "./pages/SystemStatusPage";
import { PolicyEditorPage } from "./pages/PolicyEditorPage";
import { MetricsDashboardPage } from "./pages/MetricsDashboardPage";
import { AuditLogPage } from "./pages/AuditLogPage";

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { isAuthenticated } = useAuth();
  if (!isAuthenticated) {
    return <Navigate to="/dashboard/login" replace />;
  }
  return <>{children}</>;
}

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/dashboard/login" element={<LoginPage />} />
        <Route
          path="/dashboard"
          element={
            <ProtectedRoute>
              <Layout />
            </ProtectedRoute>
          }
        >
          <Route index element={<SystemStatusPage />} />
          <Route path="policies" element={<PolicyEditorPage />} />
          <Route path="metrics" element={<MetricsDashboardPage />} />
          <Route path="logs" element={<AuditLogPage />} />
        </Route>
        <Route path="*" element={<Navigate to="/dashboard" replace />} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;
