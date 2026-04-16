import { useEffect, useCallback, useRef } from "react";
import { useAppStore } from "../../stores/appStore";
import { useTerminalStore } from "../../stores/terminalStore";
import { TerminalTabBar } from "./TerminalTabBar";
import { XTermInstance } from "./XTermInstance";

export function AgentTerminalPanel() {
  const activeTab = useAppStore((s) => s.activeTab);
  const selectedBarrack = useAppStore((s) => s.selectedBarrack);
  const sessions = useTerminalStore((s) => s.sessions);
  const activeTerminalPerBarrack = useTerminalStore((s) => s.activeTerminalPerBarrack);
  const panelWidthPerBarrack = useTerminalStore((s) => s.panelWidthPerBarrack);
  const setPanelWidth = useTerminalStore((s) => s.setPanelWidth);
  const setIsResizing = useTerminalStore((s) => s.setIsResizing);

  const bp = selectedBarrack?.path ?? "";
  const barrackSessions = sessions.filter((s) => s.barrackPath === bp);
  const activeTerminalId = activeTerminalPerBarrack[bp] ?? null;
  const panelWidth = panelWidthPerBarrack[bp] ?? 480;
  const isVisible = activeTab === "sessions" && selectedBarrack != null;
  const hasTerminals = barrackSessions.length > 0;

  // Auto-select first terminal if none active
  const setActiveTerminal = useTerminalStore((s) => s.setActiveTerminal);
  useEffect(() => {
    if (bp && barrackSessions.length > 0 && !activeTerminalId) {
      setActiveTerminal(bp, barrackSessions[0].id);
    }
  }, [bp, barrackSessions, activeTerminalId, setActiveTerminal]);

  // Resize handle
  const isDragging = useRef(false);
  const handleMouseDown = useCallback(
    (e: React.MouseEvent) => {
      if (!bp) return;
      e.preventDefault();
      isDragging.current = true;
      setIsResizing(true);

      const startX = e.clientX;
      const startWidth = panelWidth;

      const handleMouseMove = (e: MouseEvent) => {
        if (!isDragging.current) return;
        const delta = startX - e.clientX;
        const newWidth = Math.max(280, Math.min(Math.floor(window.innerWidth / 2), startWidth + delta));
        setPanelWidth(bp, newWidth);
      };

      const handleMouseUp = () => {
        isDragging.current = false;
        setIsResizing(false);
        document.removeEventListener("mousemove", handleMouseMove);
        document.removeEventListener("mouseup", handleMouseUp);
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
      };

      document.body.style.cursor = "col-resize";
      document.body.style.userSelect = "none";
      document.addEventListener("mousemove", handleMouseMove);
      document.addEventListener("mouseup", handleMouseUp);
    },
    [bp, panelWidth, setPanelWidth, setIsResizing]
  );

  // Keyboard shortcuts: Cmd+= / Cmd+- for font size
  const updateSettings = useTerminalStore((s) => s.updateSettings);
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
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
  }, [updateSettings]);

  // Panel visible only when on Agents tab AND current barrack has terminals
  const showPanel = isVisible && hasTerminals;

  // No sessions at all → nothing to keep alive
  if (sessions.length === 0) return null;

  // Single render tree: XTermInstances never unmount/remount when showPanel toggles.
  // When hidden, the wrapper moves off-screen; when visible, it joins the flex layout.
  return (
    <div
      className={showPanel ? "flex flex-row flex-shrink-0" : undefined}
      style={
        showPanel
          ? { width: panelWidth }
          : { position: "fixed", left: -9999, top: -9999, width: 1, height: 1, overflow: "hidden" }
      }
    >
      {/* Resize handle — only when panel is visible */}
      {showPanel && (
        <div
          onMouseDown={handleMouseDown}
          className="w-1 cursor-col-resize bg-cc-border hover:bg-cc-accent transition-colors flex-shrink-0"
        />
      )}

      {/* Terminal container */}
      <div className={showPanel ? "flex flex-col flex-1 overflow-hidden bg-cc-bg border-l border-cc-border" : undefined}>
        {showPanel && (
          <TerminalTabBar
            barrackPath={bp}
            sessions={barrackSessions}
            activeTerminalId={activeTerminalId}
          />
        )}
        <div className={showPanel ? "flex-1 relative overflow-hidden" : undefined}>
          {sessions.map((s) => (
            <XTermInstance
              key={s.id}
              session={s}
              visible={showPanel && s.id === activeTerminalId && s.barrackPath === bp}
            />
          ))}
        </div>
      </div>
    </div>
  );
}
