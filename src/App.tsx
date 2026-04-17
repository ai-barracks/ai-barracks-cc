import { useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useAppStore } from "./stores/appStore";
import { useNotificationStore } from "./stores/notificationStore";
import { useTerminalStore } from "./stores/terminalStore";
import { Sidebar } from "./components/layout/Sidebar";
import { MainContent } from "./components/layout/MainContent";
import { AgentTerminalPanel } from "./components/terminal/AgentTerminalPanel";
import { NotificationToast } from "./components/system/NotificationToast";
import { CommandPalette } from "./components/system/CommandPalette";

interface StaleSessionPayload {
  barrack_path: string;
  barrack_name: string;
  session_id: string;
  client: string;
  task: string;
  hours: number;
}

interface SyncNeededPayload {
  outdated_count: number;
  cli_version: string;
}

function App() {
  const { fetchBarracks, fetchCliVersion, fetchAppVersion } = useAppStore();
  const addNotification = useNotificationStore((s) => s.addNotification);

  // Reconnect surviving PTY sessions after reload
  useEffect(() => {
    invoke<{ id: string; is_connected: boolean }[]>("terminal_list")
      .then((terminals) => {
        if (terminals.length > 0) {
          const survivingIds = new Set(terminals.map((t) => t.id));
          useTerminalStore.getState().reconnectSessions(survivingIds);
        }
      })
      .catch(() => {});
  }, []);

  // Prevent accidental reload/close when terminals are active
  useEffect(() => {
    const handleBeforeUnload = (e: BeforeUnloadEvent) => {
      const sessions = useTerminalStore.getState().sessions;
      if (sessions.length > 0) {
        e.preventDefault();
      }
    };
    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => window.removeEventListener("beforeunload", handleBeforeUnload);
  }, []);

  useEffect(() => {
    fetchBarracks();
    fetchCliVersion();
    fetchAppVersion();
    const saved = localStorage.getItem("cc-theme") ?? "dark";
    document.documentElement.setAttribute("data-theme", saved);

    const unlistenFile = listen("file-changed", () => {
      fetchBarracks();
    });

    // Polling fallback: sidebar barrack counts (active sessions, etc.)
    const poll = setInterval(fetchBarracks, 10000);

    const unlistenStale = listen<StaleSessionPayload>("stale-session", (event) => {
      const d = event.payload;
      addNotification({
        type: "stale-session",
        title: `Stale: ${d.barrack_name}`,
        body: `${d.client} idle ${d.hours}h — ${d.task}`,
        data: d as unknown as Record<string, unknown>,
      });
    });

    const unlistenSync = listen<SyncNeededPayload>("sync-needed", (event) => {
      const d = event.payload;
      addNotification({
        type: "sync-needed",
        title: "Sync Required",
        body: `${d.outdated_count} barrack(s) need sync to v${d.cli_version}`,
        data: d as unknown as Record<string, unknown>,
      });
    });

    return () => {
      unlistenFile.then((fn) => fn());
      unlistenStale.then((fn) => fn());
      unlistenSync.then((fn) => fn());
      clearInterval(poll);
    };
  }, [fetchBarracks, fetchCliVersion, fetchAppVersion, addNotification]);

  return (
    <div className="flex h-screen overflow-hidden">
      <Sidebar />
      <MainContent />
      <AgentTerminalPanel />
      <NotificationToast />
      <CommandPalette />
    </div>
  );
}

export default App;
