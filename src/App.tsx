import { useEffect } from "react";
import { useAppStore } from "./stores/appStore";
import { Sidebar } from "./components/layout/Sidebar";
import { MainContent } from "./components/layout/MainContent";

function App() {
  const { fetchBarracks, fetchCliVersion } = useAppStore();

  useEffect(() => {
    fetchBarracks();
    fetchCliVersion();
    // Apply saved theme on mount
    const saved = localStorage.getItem("cc-theme") ?? "dark";
    document.documentElement.setAttribute("data-theme", saved);
  }, [fetchBarracks, fetchCliVersion]);

  return (
    <div className="flex h-screen overflow-hidden">
      <Sidebar />
      <MainContent />
    </div>
  );
}

export default App;
