import { invoke } from "@tauri-apps/api/core";
import {
  useNotificationStore,
  type AppNotification,
} from "../../stores/notificationStore";
import { useTerminalStore } from "../../stores/terminalStore";
import type { LaunchCommand } from "../../types";

function getClientKey(client: string): string {
  const lower = client.toLowerCase();
  if (lower.includes("claude")) return "claude";
  if (lower.includes("gemini")) return "gemini";
  if (lower.includes("codex")) return "codex";
  return lower.split(" ")[0];
}

function NotificationItem({ notification }: { notification: AppNotification }) {
  const dismiss = useNotificationStore((s) => s.dismissNotification);
  const addSession = useTerminalStore((s) => s.addSession);

  const handleResume = async () => {
    const { barrack_path, session_id, client } = notification.data as {
      barrack_path: string;
      session_id: string;
      client: string;
    };
    const clientKey = getClientKey(client);
    try {
      const cmd = await invoke<LaunchCommand>("get_continue_command", {
        barrackPath: barrack_path,
        client: clientKey,
        sessionId: session_id,
        skipPermissions: false,
      });
      addSession({
        id: crypto.randomUUID(),
        title: `${client} - Resume ${session_id}`,
        barrackPath: barrack_path,
        client: clientKey,
        cwd: cmd.cwd,
        initialCommand: cmd.command,
      });
    } catch (e) {
      console.error("Resume failed:", e);
    }
    dismiss(notification.id);
  };

  const handleSync = () => {
    addSession({
      id: crypto.randomUUID(),
      title: "Sync All",
      initialCommand: `${getAibPath()} barracks list`,
    });
    dismiss(notification.id);
  };

  const typeStyles =
    notification.type === "stale-session"
      ? "border-cc-warning/30 bg-cc-warning/5"
      : "border-cc-accent/30 bg-cc-accent/5";

  return (
    <div
      className={`flex items-start gap-2 p-3 rounded-lg border ${typeStyles} text-xs animate-slide-in`}
    >
      <div className="flex-1 min-w-0">
        <div className="font-medium text-cc-text">{notification.title}</div>
        <div className="text-cc-text-dim mt-0.5 truncate">{notification.body}</div>
      </div>
      <div className="flex items-center gap-1 flex-shrink-0">
        {notification.type === "stale-session" && (
          <button
            onClick={handleResume}
            className="px-2 py-1 text-[10px] font-medium bg-cc-accent text-white rounded hover:bg-cc-accent-dim transition-colors"
          >
            Resume
          </button>
        )}
        {notification.type === "sync-needed" && (
          <button
            onClick={handleSync}
            className="px-2 py-1 text-[10px] font-medium bg-cc-accent text-white rounded hover:bg-cc-accent-dim transition-colors"
          >
            Sync
          </button>
        )}
        <button
          onClick={() => dismiss(notification.id)}
          className="px-1 py-1 text-cc-text-muted hover:text-cc-text transition-colors"
        >
          x
        </button>
      </div>
    </div>
  );
}

function getAibPath(): string {
  return "/opt/homebrew/bin/aib";
}

export function NotificationToast() {
  const notifications = useNotificationStore((s) => s.notifications);

  if (notifications.length === 0) return null;

  return (
    <div className="fixed top-3 right-3 w-80 z-50 flex flex-col gap-2">
      {notifications.map((n) => (
        <NotificationItem key={n.id} notification={n} />
      ))}
    </div>
  );
}
