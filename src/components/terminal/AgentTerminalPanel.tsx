import { useEffect, useCallback, useRef, useMemo } from "react";
import { useAppStore } from "../../stores/appStore";
import { useTerminalStore } from "../../stores/terminalStore";
import { TerminalTabBar } from "./TerminalTabBar";
import { XTermInstance } from "./XTermInstance";
import { SlotHeader } from "./SlotHeader";
import type { ViewMode } from "../../types";

function getGridStyle(mode: ViewMode): React.CSSProperties {
  switch (mode) {
    case "split-horizontal":
      return { display: "grid", gridTemplateColumns: "1fr 1fr", gridTemplateRows: "1fr", gap: "1px" };
    case "split-vertical":
      return { display: "grid", gridTemplateColumns: "1fr", gridTemplateRows: "1fr 1fr", gap: "1px" };
    case "grid":
      return { display: "grid", gridTemplateColumns: "1fr 1fr", gridTemplateRows: "1fr 1fr", gap: "1px" };
    default:
      return {};
  }
}

function getMinPanelWidth(mode: ViewMode): number {
  if (mode === "split-horizontal" || mode === "grid") return 560;
  return 280;
}

export function AgentTerminalPanel() {
  const activeTab = useAppStore((s) => s.activeTab);
  const selectedBarrack = useAppStore((s) => s.selectedBarrack);
  const sessions = useTerminalStore((s) => s.sessions);
  const activeTerminalPerBarrack = useTerminalStore((s) => s.activeTerminalPerBarrack);
  const panelWidthPerBarrack = useTerminalStore((s) => s.panelWidthPerBarrack);
  const splitLayoutPerBarrack = useTerminalStore((s) => s.splitLayoutPerBarrack);
  const setPanelWidth = useTerminalStore((s) => s.setPanelWidth);
  const setIsResizing = useTerminalStore((s) => s.setIsResizing);

  const bp = selectedBarrack?.path ?? "";
  const barrackSessions = sessions.filter((s) => s.barrackPath === bp);
  const activeTerminalId = activeTerminalPerBarrack[bp] ?? null;
  const panelWidth = panelWidthPerBarrack[bp] ?? 480;
  const splitLayout = splitLayoutPerBarrack[bp];
  const viewMode = splitLayout?.mode ?? "single";
  const isGridMode = viewMode !== "single";
  const slots = splitLayout?.slots ?? [];
  const isVisible = activeTab === "sessions" && selectedBarrack != null;
  const hasTerminals = barrackSessions.length > 0;

  // Build a slot lookup: sessionId → slotIndex
  const slotMap = useMemo(() => {
    const map = new Map<string, number>();
    if (isGridMode) {
      slots.forEach((id, i) => { if (id) map.set(id, i); });
    }
    return map;
  }, [isGridMode, slots]);

  // Auto-select first terminal if none active
  const setActiveTerminal = useTerminalStore((s) => s.setActiveTerminal);
  useEffect(() => {
    if (bp && barrackSessions.length > 0 && !activeTerminalId) {
      setActiveTerminal(bp, barrackSessions[0].id);
    }
  }, [bp, barrackSessions, activeTerminalId, setActiveTerminal]);

  // Resize handle
  const isDragging = useRef(false);
  const minWidth = getMinPanelWidth(viewMode);

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
        const sidebarWidth = 240;
        const minMainContentWidth = 60;
        const maxWidth = window.innerWidth - sidebarWidth - minMainContentWidth;
        const newWidth = Math.max(minWidth, Math.min(maxWidth, startWidth + delta));
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
    [bp, panelWidth, minWidth, setPanelWidth, setIsResizing]
  );

  // Double-click resize handle to toggle max/default width
  const handleDoubleClick = useCallback(() => {
    if (!bp) return;
    const sidebarWidth = 240;
    const minMainContentWidth = 60;
    const maxWidth = window.innerWidth - sidebarWidth - minMainContentWidth;
    setPanelWidth(bp, panelWidth >= maxWidth - 10 ? 480 : maxWidth);
  }, [bp, panelWidth, setPanelWidth]);

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

  return (
    <div
      className={showPanel ? "flex flex-row flex-shrink-0" : undefined}
      style={
        showPanel
          ? { width: panelWidth }
          : { position: "fixed", left: -9999, top: -9999, width: 1, height: 1, overflow: "hidden" }
      }
    >
      {/* Resize handle */}
      {showPanel && (
        <div
          onMouseDown={handleMouseDown}
          onDoubleClick={handleDoubleClick}
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

        {/* Terminal instances — uses CSS Grid in split/grid mode, flat list in single mode.
            XTermInstances never unmount: they use stable key={s.id} and display toggle. */}
        <div
          className={showPanel ? (isGridMode ? "flex-1 min-h-0" : "flex-1 min-h-0 relative overflow-hidden flex flex-col") : undefined}
          style={showPanel && isGridMode ? { ...getGridStyle(viewMode), background: "var(--cc-border)" } : undefined}
        >
          {/* Empty slot placeholders (grid mode only) */}
          {showPanel && isGridMode && slots.map((slotId, i) => {
            if (slotId !== null) return null;
            return (
              <div
                key={`empty-${i}`}
                className="flex flex-col overflow-hidden bg-cc-bg"
                style={{ order: i }}
              >
                <SlotHeader
                  barrackPath={bp}
                  slotIndex={i}
                  session={null}
                  availableSessions={barrackSessions}
                />
                <div className="flex-1 flex items-center justify-center text-cc-text-muted text-xs">
                  Select a session
                </div>
              </div>
            );
          })}

          {/* All session instances — flat list, visibility via display toggle */}
          {sessions.map((s) => {
            const slotIndex = slotMap.get(s.id) ?? -1;
            const isVisibleSingle = !isGridMode && s.id === activeTerminalId && s.barrackPath === bp;
            const isVisibleGrid = isGridMode && slotIndex !== -1 && s.barrackPath === bp;
            const visible = showPanel && (isVisibleSingle || isVisibleGrid);

            return (
              <div
                key={s.id}
                className={visible ? "flex flex-col overflow-hidden bg-cc-bg" : undefined}
                style={{
                  display: visible ? "flex" : "none",
                  flex: visible ? 1 : undefined,
                  minHeight: visible ? 0 : undefined,
                  flexDirection: "column",
                  overflow: "hidden",
                  ...(isGridMode && visible ? { order: slotIndex } : {}),
                }}
              >
                {isGridMode && visible && (
                  <SlotHeader
                    barrackPath={bp}
                    slotIndex={slotIndex}
                    session={s}
                    availableSessions={barrackSessions}
                  />
                )}
                <div className="flex-1 min-h-0 relative overflow-hidden">
                  <XTermInstance session={s} visible={visible} />
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
