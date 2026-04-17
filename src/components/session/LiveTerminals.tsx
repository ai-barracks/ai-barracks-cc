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
          const dotColor = CLIENT_DOTS[s.client ?? ""] ?? "bg-gray-400";

          return (
            <button
              key={s.id}
              onClick={() => setActiveTerminal(bp, s.id)}
              className={`group flex items-center gap-1.5 px-2.5 py-1.5 rounded-md border text-left transition-colors ${
                isActive
                  ? "bg-cc-accent/10 border-cc-accent/30 text-cc-text"
                  : "bg-cc-bg border-cc-border text-cc-text-dim hover:border-cc-accent/20 hover:bg-cc-accent/5"
              }`}
            >
              <span className={`w-2 h-2 rounded-full ${dotColor} flex-shrink-0`} />
              <span className="text-xs truncate max-w-[140px]">{s.title}</span>
              {s.source && s.source !== "terminal" && (
                <span className="text-[9px] text-cc-text-muted uppercase">{s.source}</span>
              )}
              <span
                onClick={(e) => {
                  e.stopPropagation();
                  removeSession(s.id);
                }}
                className="text-cc-text-muted hover:text-cc-danger ml-0.5 opacity-0 group-hover:opacity-100 transition-opacity text-xs"
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
