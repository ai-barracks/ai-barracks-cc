import { useRef, useCallback } from "react";
import { useTerminal } from "../../hooks/useTerminal";
import { useTerminalStore } from "../../stores/terminalStore";
import { ArchiveTermView } from "./ArchiveTermView";
import type { TerminalSession } from "../../types";

interface XTermInstanceProps {
  session: TerminalSession;
  visible: boolean;
}

export function XTermInstance({ session, visible }: XTermInstanceProps) {
  // Archive tabs are dead, read-only sessions: render a self-contained
  // read-only view that never attaches a PTY. The live `useTerminal` hook
  // below is reserved for interactive sessions only (zero regression).
  if (session.mode === "archive") {
    return <ArchiveTermView session={session} visible={visible} />;
  }
  return <LiveXTermInstance session={session} visible={visible} />;
}

function LiveXTermInstance({ session, visible }: XTermInstanceProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const removeSession = useTerminalStore((s) => s.removeSession);
  const setPtyId = useTerminalStore((s) => s.setPtyId);
  const markExited = useTerminalStore((s) => s.markExited);

  const handleExit = useCallback(() => {
    markExited(session.id);
    if (session.autoCloseOnExit) {
      setTimeout(() => removeSession(session.id), 3000);
    }
  }, [session.id, session.autoCloseOnExit, removeSession, markExited]);

  const handlePtyCreated = useCallback((ptyId: string) => {
    setPtyId(session.id, ptyId);
  }, [session.id, setPtyId]);

  useTerminal({
    sessionId: session.id,
    containerRef,
    cwd: session.cwd,
    initialCommand: session.initialCommand,
    visible,
    onExit: handleExit,
    onPtyCreated: handlePtyCreated,
    reconnectTerminalId: session.ptyId,
  });

  return (
    <div
      ref={containerRef}
      className="w-full h-full"
      style={{
        display: visible ? "block" : "none",
        padding: "4px 8px",
      }}
    />
  );
}
