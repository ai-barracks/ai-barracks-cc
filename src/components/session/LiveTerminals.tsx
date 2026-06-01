import { useTerminalStore } from "../../stores/terminalStore";
import { useAppStore } from "../../stores/appStore";

const CLIENT_DOTS: Record<string, string> = {
  claude: "bg-orange-400",
  gemini: "bg-blue-400",
  codex: "bg-green-400",
};

export function LiveTerminals() {
  const selectedBarrack = useAppStore((s) => s.selectedBarrack);
  const sessions = useTerminalStore((s) => s.sessions);
  const activeTerminalPerBarrack = useTerminalStore((s) => s.activeTerminalPerBarrack);
  const setActiveTerminal = useTerminalStore((s) => s.setActiveTerminal);
  const removeSession = useTerminalStore((s) => s.removeSession);

  const bp = selectedBarrack?.path ?? "";
  const barrackSessions = sessions.filter((s) => s.barrackPath === bp);
  const activeTerminalId = activeTerminalPerBarrack[bp] ?? null;

  if (barrackSessions.length === 0) return null;

  return (
    <div className="mb-4 p-3 bg-cc-panel border border-cc-border rounded-lg">
      <div className="flex items-center gap-2 mb-2">
        <span className="text-xs font-medium text-cc-text-muted uppercase tracking-wider">
          Live Terminals
        </span>
        <span className="text-[10px] text-cc-text-muted bg-cc-bg px-1.5 py-0.5 rounded">
          {barrackSessions.length}
        </span>
      </div>
      <div className="flex flex-wrap gap-1.5">
        {barrackSessions.map((s) => {
          const isActive = s.id === activeTerminalId;
          const isArchive = s.mode === "archive";
          const dotColor = isArchive
            ? "bg-cc-text-muted/50"
            : s.exited
              ? "bg-red-400 opacity-50"
              : (CLIENT_DOTS[s.client ?? ""] ?? "bg-gray-400");

          return (
            <button
              key={s.id}
              onClick={() => setActiveTerminal(bp, s.id)}
              className={`group flex items-center gap-1.5 px-2.5 py-1.5 rounded-md border text-left transition-colors ${
                isArchive
                  ? isActive
                    ? "bg-cc-text-muted/10 border-cc-text-muted/40 text-cc-text-dim"
                    : "bg-cc-bg border-cc-border border-dashed text-cc-text-muted hover:border-cc-text-muted/30"
                  : s.exited
                    ? "opacity-50 bg-cc-bg border-cc-border text-cc-text-muted"
                    : isActive
                      ? "bg-cc-accent/10 border-cc-accent/30 text-cc-text"
                      : "bg-cc-bg border-cc-border text-cc-text-dim hover:border-cc-accent/20 hover:bg-cc-accent/5"
              }`}
            >
              <span className={`w-2 h-2 rounded-full ${dotColor} flex-shrink-0`} />
              <span className={`text-xs truncate max-w-[140px] ${!isArchive && s.exited ? "line-through" : ""}`}>{s.title}</span>
              {isArchive && (
                <span className="text-[9px] text-cc-text-muted uppercase">archive</span>
              )}
              {!isArchive && s.exited && (
                <span className="text-[9px] text-red-400 uppercase">exited</span>
              )}
              {!isArchive && !s.exited && s.source && s.source !== "terminal" && (
                <span className="text-[9px] text-cc-text-muted uppercase">{s.source}</span>
              )}
              <span
                onClick={(e) => {
                  e.stopPropagation();
                  removeSession(s.id);
                }}
                className={`hover:text-cc-danger ml-0.5 transition-opacity text-xs ${
                  s.exited
                    ? "text-cc-text-muted opacity-100"
                    : "text-cc-text-muted opacity-0 group-hover:opacity-100"
                }`}
              >
                ×
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
