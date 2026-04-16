import type { EmbeddedSession } from "./embeddedTerminalReducer";

interface EmbeddedTerminalTabBarProps {
  sessions: EmbeddedSession[];
  activeId: string | null;
  onSelect: (id: string) => void;
  onClose: (id: string) => void;
}

export function EmbeddedTerminalTabBar({
  sessions,
  activeId,
  onSelect,
  onClose,
}: EmbeddedTerminalTabBarProps) {
  return (
    <div className="flex items-center h-9 bg-cc-sidebar border-b border-cc-border flex-shrink-0 px-2 gap-1">
      <span className="text-[10px] text-cc-text-muted font-medium uppercase tracking-wider flex-shrink-0">
        Agent
      </span>
      <div className="flex items-center gap-0.5 flex-1 overflow-x-auto min-w-0">
        {sessions.map((s) => (
          <button
            key={s.id}
            onClick={() => onSelect(s.id)}
            className={`flex items-center gap-1 px-2 py-1 text-[11px] rounded transition-colors whitespace-nowrap flex-shrink-0 ${
              activeId === s.id
                ? "bg-cc-panel text-cc-text"
                : "text-cc-text-dim hover:text-cc-text hover:bg-cc-card-hover"
            }`}
          >
            <span className="truncate max-w-[110px]">{s.title}</span>
            <span
              onClick={(e) => {
                e.stopPropagation();
                onClose(s.id);
              }}
              className="text-cc-text-muted hover:text-cc-danger transition-colors ml-0.5 leading-none text-base"
            >
              ×
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}
