import { NavLink, useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";

const NAV_ITEMS = [
  { to: "/dashboard", label: "System Status", icon: "🏠" },
  { to: "/dashboard/policies", label: "Policy Editor", icon: "📋" },
  { to: "/dashboard/metrics", label: "Metrics", icon: "📊" },
  { to: "/dashboard/logs", label: "Audit Logs", icon: "📜" },
] as const;

export function Sidebar() {
  const { logout } = useAuth();
  const navigate = useNavigate();

  const handleLogout = () => {
    logout();
    navigate("/dashboard/login");
  };

  return (
    <aside className="flex w-56 flex-col border-r border-gray-200 bg-white">
      <div className="border-b border-gray-200 px-4 py-4">
        <h1 className="text-lg font-bold text-gray-900">LuaGate</h1>
        <p className="text-xs text-gray-500">Admin Dashboard</p>
      </div>

      <nav className="flex-1 space-y-1 px-2 py-4">
        {NAV_ITEMS.map(({ to, label, icon }) => (
          <NavLink
            key={to}
            to={to}
            end={to === "/dashboard"}
            className={({ isActive }) =>
              `flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium ${
                isActive
                  ? "bg-blue-50 text-blue-700"
                  : "text-gray-700 hover:bg-gray-100"
              }`
            }
          >
            <span>{icon}</span>
            {label}
          </NavLink>
        ))}
      </nav>

      <div className="border-t border-gray-200 p-2">
        <button
          onClick={handleLogout}
          className="w-full rounded-md px-3 py-2 text-left text-sm text-gray-600 hover:bg-gray-100"
        >
          Logout
        </button>
      </div>
    </aside>
  );
}
