import { useRef } from "react";
import { useTerminal } from "../../hooks/useTerminal";
import type { EmbeddedSession } from "./embeddedTerminalReducer";

interface EmbeddedTerminalInstanceProps {
  session: EmbeddedSession;
  visible: boolean;
}

export function EmbeddedTerminalInstance({ session, visible }: EmbeddedTerminalInstanceProps) {
  const containerRef = useRef<HTMLDivElement>(null);

  useTerminal({
    sessionId: session.id,
    containerRef,
    cwd: session.cwd,
    initialCommand: session.initialCommand,
    visible,
  });

  return (
    <div
      ref={containerRef}
      style={{
        display: visible ? "block" : "none",
        width: "100%",
        height: "100%",
        padding: "4px 8px",
      }}
    />
  );
}
