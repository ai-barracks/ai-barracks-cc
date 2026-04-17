import { useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useTerminalStore, getBuffer } from "../../stores/terminalStore";
import { TerminalSettingsPanel } from "./TerminalSettings";
import type { TerminalSession, ViewMode } from "../../types";

interface TerminalTabBarProps {
  barrackPath: string;
  sessions: TerminalSession[];
  activeTerminalId: string | null;
}

function slotsForMode(mode: ViewMode): number {
  if (mode === "single") return 1;
  if (mode === "grid") return 4;
  return 2;
}

const VIEW_MODES: { mode: ViewMode; label: string; icon: string }[] = [
  { mode: "single", label: "Single", icon: "\u25A1" },
  { mode: "split-horizontal", label: "Split H", icon: "\u25EB" },
  { mode: "split-vertical", label: "Split V", icon: "\u2B12" },
  { mode: "grid", label: "Grid", icon: "\u2B1A" },
];

function getMinPanelWidth(mode: ViewMode): number {
  if (mode === "split-horizontal" || mode === "grid") return 560;
  return 280;
}

export function TerminalTabBar({ barrackPath, sessions, activeTerminalId }: TerminalTabBarProps) {
  const { addSession, addQuickCommand } = useTerminalStore();
  const splitLayout = useTerminalStore((s) => s.splitLayoutPerBarrack[barrackPath]);
  const setSplitLayout = useTerminalStore((s) => s.setSplitLayout);
  const setPanelWidth = useTerminalStore((s) => s.setPanelWidth);
  const panelWidth = useTerminalStore((s) => s.panelWidthPerBarrack[barrackPath] ?? 480);
  const [showSettings, setShowSettings] = useState(false);

  const currentMode = splitLayout?.mode ?? "single";

  const handleViewModeChange = useCallback((mode: ViewMode) => {
    const slotCount = slotsForMode(mode);
    const sessionIds = sessions.map((s) => s.id);
    const slots: (string | null)[] = Array.from({ length: slotCount }, (_, i) => sessionIds[i] ?? null);
    setSplitLayout(barrackPath, { mode, slots });

    const minWidth = getMinPanelWidth(mode);
    if (panelWidth < minWidth) {
      setPanelWidth(barrackPath, minWidth);
    }
  }, [barrackPath, sessions, panelWidth, setSplitLayout, setPanelWidth]);

  const handleNewTerminal = () => {
    addSession({
      id: crypto.randomUUID(),
      title: "zsh",
      barrackPath,
      cwd: barrackPath,
      source: "terminal",
    });
  };

  const handleExport = async () => {
    if (!activeTerminalId) return;
    const session = sessions.find((s) => s.id === activeTerminalId);
    if (!session) return;

    const content = getBuffer(activeTerminalId);
    if (!content.trim()) {
      alert("Export할 출력이 없습니다.");
      return;
    }

    const timestamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
    const filename = `terminal-${session.title.replace(/[^a-zA-Z0-9가-힣_-]/g, "_")}-${timestamp}.txt`;
    const dir = `${session.barrackPath}/sessions`;
    const filePath = `${dir}/${filename}`;

    try {
      await invoke("write_file", { filePath, content });
      alert(`Exported: ${filePath}`);
    } catch (e) {
      alert(`Export 실패: ${e}`);
    }
  };

  const handleSaveQuickCommand = () => {
    if (!activeTerminalId) return;
    const session = sessions.find((s) => s.id === activeTerminalId);
    if (!session?.initialCommand) {
      alert("저장할 명령어가 없습니다. (초기 명령어로 시작된 터미널만 저장 가능)");
      return;
    }

    const label = prompt("Quick Command 이름:", session.title);
    if (!label) return;

    addQuickCommand({
      id: crypto.randomUUID(),
      label,
      command: session.initialCommand,
      cwd: session.cwd,
    });
  };

  return (
    <div className="flex items-center h-7 bg-cc-sidebar border-b border-cc-border px-1 flex-shrink-0">
      {/* New terminal */}
      <button
        onClick={handleNewTerminal}
        className="px-2 py-0.5 text-xs text-cc-text-muted hover:text-cc-text hover:bg-cc-card-hover rounded transition-colors"
        title="New Terminal"
      >
        +
      </button>

      <div className="flex-1" />

      {/* View mode toggle */}
      <div className="flex items-center gap-0.5 border-r border-cc-border pr-2 mr-1">
        {VIEW_MODES.map((vm) => (
          <button
            key={vm.mode}
            onClick={() => handleViewModeChange(vm.mode)}
            className={`px-1.5 py-0.5 text-[11px] rounded transition-colors ${
              currentMode === vm.mode
                ? "bg-cc-accent/20 text-cc-accent"
                : "text-cc-text-muted hover:text-cc-text-dim hover:bg-cc-card-hover"
            }`}
            title={vm.label}
          >
            {vm.icon}
          </button>
        ))}
      </div>

      {/* Actions */}
      <div className="flex items-center gap-1 relative">
        {activeTerminalId && (
          <>
            <button
              onClick={handleExport}
              className="px-1.5 py-0.5 text-[11px] text-cc-text-muted hover:text-cc-text transition-colors"
              title="Export terminal output"
            >
              Export
            </button>
            <button
              onClick={handleSaveQuickCommand}
              className="px-1.5 py-0.5 text-[11px] text-cc-text-muted hover:text-cc-text transition-colors"
              title="Save as Quick Command"
            >
              Save
            </button>
          </>
        )}
        <button
          onClick={() => setShowSettings(!showSettings)}
          className="px-1.5 py-0.5 text-[11px] text-cc-text-muted hover:text-cc-text transition-colors"
          title="Terminal Settings"
        >
          ⚙
        </button>

        {showSettings && <TerminalSettingsPanel onClose={() => setShowSettings(false)} />}
      </div>
    </div>
  );
}
