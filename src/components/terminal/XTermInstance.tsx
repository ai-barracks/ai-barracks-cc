import { useRef, useCallback } from "react";
import { useTerminal } from "../../hooks/useTerminal";
import { useTerminalStore } from "../../stores/terminalStore";
import type { TerminalSession } from "../../types";

interface XTermInstanceProps {
  session: TerminalSession;
  visible: boolean;
}

export function XTermInstance({ session, visible }: XTermInstanceProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const removeSession = useTerminalStore((s) => s.removeSession);
  const setPtyId = useTerminalStore((s) => s.setPtyId);

  const handleExit = useCallback(() => {
    if (session.autoCloseOnExit) {
      setTimeout(() => removeSession(session.id), 3000);
    }
  }, [session.id, session.autoCloseOnExit, removeSession]);

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
