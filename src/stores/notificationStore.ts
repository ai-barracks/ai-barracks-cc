import { create } from "zustand";

export interface AppNotification {
  id: string;
  type: "stale-session" | "sync-needed";
  title: string;
  body: string;
  timestamp: number;
  data: Record<string, unknown>;
}

interface NotificationState {
  notifications: AppNotification[];
  addNotification: (n: Omit<AppNotification, "id" | "timestamp">) => void;
  dismissNotification: (id: string) => void;
  clearAll: () => void;
}

export const useNotificationStore = create<NotificationState>((set) => ({
  notifications: [],

  addNotification: (n) =>
    set((s) => {
      // Deduplicate by type + data key
      const key =
        n.type === "stale-session"
          ? `${n.data.barrack_path}:${n.data.session_id}`
          : `sync-${n.data.outdated_count}`;
      const exists = s.notifications.some(
        (existing) =>
          existing.type === n.type &&
          (n.type === "stale-session"
            ? `${existing.data.barrack_path}:${existing.data.session_id}` === key
            : existing.type === "sync-needed")
      );
      if (exists) return s;

      return {
        notifications: [
          { ...n, id: crypto.randomUUID(), timestamp: Date.now() },
          ...s.notifications,
        ].slice(0, 10), // Keep max 10
      };
    }),

  dismissNotification: (id) =>
    set((s) => ({
      notifications: s.notifications.filter((n) => n.id !== id),
    })),

  clearAll: () => set({ notifications: [] }),
}));
