interface ErrorAlertProps {
  title?: string;
  message: string;
  onDismiss?: () => void;
}

export function ErrorAlert({
  title = "Error",
  message,
  onDismiss,
}: ErrorAlertProps) {
  return (
    <div className="rounded-md border border-red-200 bg-red-50 p-4">
      <div className="flex items-start justify-between">
        <div>
          <h3 className="text-sm font-medium text-red-800">{title}</h3>
          <p className="mt-1 text-sm text-red-700">{message}</p>
        </div>
        {onDismiss && (
          <button
            onClick={onDismiss}
            className="ml-4 text-red-400 hover:text-red-600"
          >
            &times;
          </button>
        )}
      </div>
    </div>
  );
}
