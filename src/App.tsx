import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { useAppStore } from "./stores/appStore";
import { useNotificationStore } from "./stores/notificationStore";
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
  const { fetchBarracks, fetchCliVersion } = useAppStore();
  const addNotification = useNotificationStore((s) => s.addNotification);

  useEffect(() => {
    // NOTE: terminal_close_all removed — PTY sessions survive reload for reconnection

    fetchBarracks();
    fetchCliVersion();
    const saved = localStorage.getItem("cc-theme") ?? "dark";
    document.documentElement.setAttribute("data-theme", saved);

    const unlistenFile = listen("file-changed", () => {
      fetchBarracks();
    });

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
    };
  }, [fetchBarracks, fetchCliVersion, addNotification]);

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
