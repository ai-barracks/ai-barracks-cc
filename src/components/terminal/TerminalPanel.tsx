import { useEffect } from "react";
import { useTerminalStore } from "../../stores/terminalStore";
import { TerminalTabBar } from "./TerminalTabBar";
import { XTermInstance } from "./XTermInstance";
import { PanelResizeHandle } from "./PanelResizeHandle";

export function TerminalPanel() {
  const { sessions, activeTerminalId, panelVisible, panelWidth, togglePanel, showPanel, addSession, updateSettings } =
    useTerminalStore();

  // Keyboard shortcuts
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Cmd+` to toggle panel
      if (e.metaKey && e.key === "`") {
        e.preventDefault();
        togglePanel();
      }

      // Cmd+= / Cmd+- for font size (when terminal is focused)
      const terminalEl = document.querySelector(".xterm");
      if (!terminalEl?.contains(document.activeElement)) return;

      if (e.metaKey && (e.key === "=" || e.key === "+")) {
        e.preventDefault();
        const { settings } = useTerminalStore.getState();
        if (settings.fontSize < 24) {
          updateSettings({ fontSize: settings.fontSize + 1 });
        }
      }
      if (e.metaKey && e.key === "-") {
        e.preventDefault();
        const { settings } = useTerminalStore.getState();
        if (settings.fontSize > 10) {
          updateSettings({ fontSize: settings.fontSize - 1 });
        }
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [togglePanel, updateSettings]);

  return (
    <>
      {/* Toggle bar — always visible on right edge */}
      {!panelVisible && (
        <button
          onClick={() => {
            if (sessions.length === 0) {
              addSession({ id: crypto.randomUUID(), title: "zsh" });
            }
            showPanel();
          }}
          className="w-7 flex flex-col items-center justify-center py-3 text-xs text-cc-text-muted hover:text-cc-text bg-cc-sidebar border-l border-cc-border transition-colors flex-shrink-0"
          style={{ writingMode: "vertical-rl" }}
        >
          <span>Terminal</span>
          {sessions.length > 0 && (
            <span className="text-[10px] px-0.5 py-1 bg-cc-accent/20 text-cc-accent rounded mt-1">
              {sessions.length}
            </span>
          )}
        </button>
      )}

      {/* Terminal panel — right side */}
      {panelVisible && (
        <>
          <PanelResizeHandle />
          <div
            style={{ width: panelWidth }}
            className="flex flex-col bg-cc-bg border-l border-cc-border flex-shrink-0 overflow-hidden"
          >
            <TerminalTabBar />
            <div className="flex-1 relative overflow-hidden">
              {sessions.length === 0 ? (
                <div className="flex items-center justify-center h-full text-xs text-cc-text-muted">
                  No terminals. Click + to start.
                </div>
              ) : (
                sessions.map((s) => (
                  <XTermInstance
                    key={s.id}
                    session={s}
                    visible={s.id === activeTerminalId}
                  />
                ))
              )}
            </div>
          </div>
        </>
      )}
    </>
  );
}
