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

  const handleExit = useCallback(() => {
    setTimeout(() => removeSession(session.id), 3000);
  }, [session.id, removeSession]);

  useTerminal({
    sessionId: session.id,
    containerRef,
    cwd: session.cwd,
    initialCommand: session.initialCommand,
    visible,
    onExit: handleExit,
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
