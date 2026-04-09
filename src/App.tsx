import { useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { useAppStore } from "./stores/appStore";
import { Sidebar } from "./components/layout/Sidebar";
import { MainContent } from "./components/layout/MainContent";

function App() {
  const { fetchBarracks, fetchCliVersion } = useAppStore();

  useEffect(() => {
    fetchBarracks();
    fetchCliVersion();
    const saved = localStorage.getItem("cc-theme") ?? "dark";
    document.documentElement.setAttribute("data-theme", saved);

    // Listen for file changes from Rust watcher
    const unlisten = listen("file-changed", () => {
      fetchBarracks();
    });

    return () => {
      unlisten.then((fn) => fn());
    };
  }, [fetchBarracks, fetchCliVersion]);

  return (
    <div className="flex h-screen overflow-hidden">
      <Sidebar />
      <MainContent />
    </div>
  );
}

export default App;
