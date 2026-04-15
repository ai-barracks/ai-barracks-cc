import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useTerminalStore, getBuffer } from "../../stores/terminalStore";
import { TerminalSettingsPanel } from "./TerminalSettings";

export function TerminalTabBar() {
  const { sessions, activeTerminalId, setActiveTerminal, removeSession, hidePanel, addSession, addQuickCommand } =
    useTerminalStore();
  const [showSettings, setShowSettings] = useState(false);

  const handleNewTerminal = () => {
    addSession({
      id: crypto.randomUUID(),
      title: "zsh",
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

    const dir = session.barrackPath
      ? `${session.barrackPath}/sessions`
      : "/tmp";
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
    <div className="flex items-center h-9 bg-cc-sidebar border-b border-cc-border px-1 flex-shrink-0">
      {/* Terminal tabs */}
      <div className="flex items-center gap-0.5 flex-1 overflow-x-auto min-w-0">
        {sessions.map((s) => (
          <button
            key={s.id}
            onClick={() => setActiveTerminal(s.id)}
            className={`flex items-center gap-1.5 px-2.5 py-1 text-xs rounded transition-colors whitespace-nowrap ${
              activeTerminalId === s.id
                ? "bg-cc-panel text-cc-text"
                : "text-cc-text-dim hover:text-cc-text hover:bg-cc-card-hover"
            }`}
          >
            <span className="truncate max-w-[100px]">{s.title}</span>
            <span
              onClick={(e) => {
                e.stopPropagation();
                removeSession(s.id);
              }}
              className="text-cc-text-muted hover:text-cc-danger ml-0.5 transition-colors"
            >
              x
            </span>
          </button>
        ))}

        {/* New terminal button */}
        <button
          onClick={handleNewTerminal}
          className="px-2 py-1 text-xs text-cc-text-muted hover:text-cc-text hover:bg-cc-card-hover rounded transition-colors"
          title="New Terminal"
        >
          +
        </button>
      </div>

      {/* Right actions */}
      <div className="flex items-center gap-1 ml-2 relative">
        {activeTerminalId && (
          <>
            <button
              onClick={handleExport}
              className="px-1.5 py-1 text-xs text-cc-text-muted hover:text-cc-text transition-colors"
              title="Export terminal output to file"
            >
              Export
            </button>
            <button
              onClick={handleSaveQuickCommand}
              className="px-1.5 py-1 text-xs text-cc-text-muted hover:text-cc-text transition-colors"
              title="Save as Quick Command"
            >
              Save
            </button>
          </>
        )}
        <button
          onClick={() => setShowSettings(!showSettings)}
          className="px-1.5 py-1 text-xs text-cc-text-muted hover:text-cc-text transition-colors"
          title="Terminal Settings"
        >
          Settings
        </button>
        <button
          onClick={hidePanel}
          className="px-1.5 py-1 text-xs text-cc-text-muted hover:text-cc-text transition-colors"
          title="Hide Terminal"
        >
          Hide
        </button>

        {showSettings && <TerminalSettingsPanel onClose={() => setShowSettings(false)} />}
      </div>
    </div>
  );
}

