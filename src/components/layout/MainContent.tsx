import { useEffect } from "react";
import { useAppStore } from "../../stores/appStore";
import { BarrackOverview } from "../barrack/BarrackOverview";
import { FilesTab } from "../editor/FilesTab";
import { SessionsTab } from "../session/SessionsTab";
import { WikiTab } from "../wiki/WikiTab";
import { SystemView } from "../system/SystemView";
import type { TabType } from "../../types";

const TABS: { key: TabType; label: string }[] = [
  { key: "overview", label: "Overview" },
  { key: "files", label: "Config" },
  { key: "sessions", label: "Agents" },
  { key: "wiki", label: "Wiki" },
];

// Empty state removed — SystemView is shown when no barrack is selected

export function MainContent() {
  const { selectedBarrack, activeTab, setActiveTab, fetchBarracks } = useAppStore();

  // Refresh data when switching tabs or selecting a different barrack
  useEffect(() => {
    if (selectedBarrack) {
      fetchBarracks();
    }
  }, [activeTab, selectedBarrack?.path, fetchBarracks]);

  if (!selectedBarrack) {
    return <SystemView />;
  }

  return (
    <div className="flex-1 flex flex-col overflow-hidden bg-cc-bg">
      {/* Tab bar */}
      <div className="flex items-center gap-1 border-b border-cc-border px-4 h-10 shrink-0">
        {TABS.map((tab) => (
          <button
            key={tab.key}
            onClick={() => setActiveTab(tab.key)}
            className={`px-3 h-full text-[13px] font-medium border-b-2 -mb-px transition-colors ${
              activeTab === tab.key
                ? "border-cc-accent text-cc-text"
                : "border-transparent text-cc-text-muted hover:text-cc-text-dim"
            }`}
          >
            {tab.label}
          </button>
        ))}
        <div className="flex-1" />
        <span className="text-[11px] text-cc-text-muted truncate max-w-[280px]">
          {selectedBarrack.path}
        </span>
      </div>

      {/* Tab content */}
      <div className="flex-1 overflow-y-auto">
        {activeTab === "overview" && <BarrackOverview />}
        {activeTab === "files" && <FilesTab />}
        {activeTab === "sessions" && <SessionsTab />}
        {activeTab === "wiki" && <WikiTab />}
      </div>
    </div>
  );
}
