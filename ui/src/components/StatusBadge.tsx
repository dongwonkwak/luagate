interface StatusBadgeProps {
  status: "ok" | "unhealthy" | string;
}

export function StatusBadge({ status }: StatusBadgeProps) {
  const isOk = status === "ok";
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-medium ${
        isOk ? "bg-green-100 text-green-800" : "bg-red-100 text-red-800"
      }`}
    >
      <span
        className={`h-1.5 w-1.5 rounded-full ${isOk ? "bg-green-500" : "bg-red-500"}`}
      />
      {status}
    </span>
  );
}
