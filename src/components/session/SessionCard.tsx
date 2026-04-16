import type { SessionInfo, SessionDetail } from "../../types";

const CLIENT_BADGES: Record<string, string> = {
  "Claude Code": "bg-orange-500/15 text-orange-400 border-orange-500/20",
  "Gemini CLI": "bg-blue-500/15 text-blue-400 border-blue-500/20",
  "Codex CLI": "bg-green-500/15 text-green-400 border-green-500/20",
};

const CLIENT_SHORT: Record<string, string> = {
  "Claude Code": "Claude",
  "Gemini CLI": "Gemini",
  "Codex CLI": "Codex",
};

const STATUS_STYLES: Record<string, string> = {
  active: "bg-cc-success/20 text-cc-success",
  completed: "bg-blue-500/20 text-blue-400",
  interrupted: "bg-cc-warning/20 text-cc-warning",
};

function Section({ title, items, color }: { title: string; items: string[]; color?: string }) {
  return (
    <div>
      <h4 className="text-xs font-medium text-cc-text-muted mb-1 uppercase tracking-wider">{title}</h4>
      <ul className="space-y-0.5">
        {items.map((item, i) => (
          <li key={i} className={`text-xs ${color ?? "text-cc-text-dim"}`}>
            - {item}
          </li>
        ))}
      </ul>
    </div>
  );
}

interface SessionCardProps {
  session: SessionInfo;
  isExpanded: boolean;
  detail: SessionDetail | null;
  onToggle: () => void;
  onContinue: () => void;
  onViewInTerminal: () => void;
  onMonitor: () => void;
}

export function SessionCard({
  session,
  isExpanded,
  detail,
  onToggle,
  onContinue,
  onViewInTerminal,
  onMonitor,
}: SessionCardProps) {
  const canContinue = session.status === "completed" || session.status === "interrupted";
  const isActive = session.status === "active";

  return (
    <div className="rounded-lg overflow-hidden border border-cc-border shadow-cc">
      <div className="flex items-stretch">
        <button
          onClick={onToggle}
          className="flex-1 text-left px-4 py-3 hover:bg-cc-card-hover transition-colors"
        >
          <div className="flex items-center gap-2">
            <span className="text-[13px] font-medium text-cc-text truncate flex-1">
              {session.task || "(pending)"}
            </span>
            <span
              className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${CLIENT_BADGES[session.client] ?? "bg-gray-500/15 text-gray-400 border-gray-500/20"}`}
            >
              {CLIENT_SHORT[session.client] ?? session.client}
            </span>
            <span
              className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${STATUS_STYLES[session.status] ?? STATUS_STYLES.completed}`}
            >
              {session.status}
            </span>
          </div>
          <div className="flex items-center gap-1.5 mt-1 text-[11px] text-cc-text-muted">
            <span>{session.started}</span>
          </div>
        </button>
        {isActive && (
          <button
            onClick={(e) => { e.stopPropagation(); onMonitor(); }}
            className="px-2 border-l border-cc-border text-[11px] text-cc-success hover:bg-cc-success/10 transition-colors shrink-0 font-medium"
            title="실시간 세션 모니터링"
          >
            Monitor
          </button>
        )}
        <button
          onClick={(e) => { e.stopPropagation(); onViewInTerminal(); }}
          className="px-2 border-l border-cc-border text-[11px] text-cc-text-muted hover:text-cc-text hover:bg-cc-card-hover transition-colors shrink-0"
          title="터미널에서 세션 파일 보기"
        >
          View
        </button>
        {canContinue && (
          <button
            onClick={(e) => { e.stopPropagation(); onContinue(); }}
            className="px-3 border-l border-cc-border text-[11px] text-cc-accent hover:bg-cc-accent/10 transition-colors font-medium shrink-0"
            title="이 에이전트의 작업을 이어서 진행"
          >
            Continue
          </button>
        )}
      </div>

      {isExpanded && detail && (
        <div className="border-t border-cc-border px-4 py-3 bg-cc-panel/50 space-y-3">
          <div className="grid grid-cols-3 gap-3 text-xs">
            <div>
              <span className="text-cc-text-muted">Started: </span>
              <span className="text-cc-text-dim">{detail.info.started}</span>
            </div>
            <div>
              <span className="text-cc-text-muted">Ended: </span>
              <span className="text-cc-text-dim">{detail.info.ended}</span>
            </div>
            {detail.info.continues && detail.info.continues !== "(없음)" && (
              <div>
                <span className="text-cc-text-muted">Continues: </span>
                <span className="text-cc-text-dim">{detail.info.continues}</span>
              </div>
            )}
          </div>
          {detail.log.length > 0 && <Section title="Log" items={detail.log} />}
          {detail.decisions.length > 0 && <Section title="Decisions" items={detail.decisions} />}
          {detail.blockers.length > 0 && <Section title="Blockers" items={detail.blockers} color="text-cc-warning" />}
          {detail.wiki_extractions.length > 0 && <Section title="Wiki Extractions" items={detail.wiki_extractions} color="text-cc-success" />}
          {detail.identity_suggestions.length > 0 && <Section title="Identity Suggestions" items={detail.identity_suggestions} color="text-blue-400" />}
        </div>
      )}
    </div>
  );
}
