import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useAppStore } from "../../stores/appStore";
import { useTerminalStore } from "../../stores/terminalStore";
import type { SessionInfo, SessionDetail, LaunchCommand } from "../../types";

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

function SessionCard({
  session,
  isExpanded,
  onToggle,
  onContinue,
  onViewInTerminal,
  onMonitor,
  detail,
}: {
  session: SessionInfo;
  isExpanded: boolean;
  onToggle: () => void;
  onContinue: () => void;
  onViewInTerminal: () => void;
  onMonitor: () => void;
  detail: SessionDetail | null;
}) {
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
          {/* Meta */}
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

          {/* Log */}
          {detail.log.length > 0 && (
            <Section title="Log" items={detail.log} />
          )}

          {/* Decisions */}
          {detail.decisions.length > 0 && (
            <Section title="Decisions" items={detail.decisions} />
          )}

          {/* Blockers */}
          {detail.blockers.length > 0 && (
            <Section title="Blockers" items={detail.blockers} color="text-cc-warning" />
          )}

          {/* Wiki Extractions */}
          {detail.wiki_extractions.length > 0 && (
            <Section title="Wiki Extractions" items={detail.wiki_extractions} color="text-cc-success" />
          )}

          {/* Identity Suggestions */}
          {detail.identity_suggestions.length > 0 && (
            <Section title="Identity Suggestions" items={detail.identity_suggestions} color="text-blue-400" />
          )}
        </div>
      )}
    </div>
  );
}

function Section({
  title,
  items,
  color,
}: {
  title: string;
  items: string[];
  color?: string;
}) {
  return (
    <div>
      <h4 className="text-xs font-medium text-cc-text-muted mb-1 uppercase tracking-wider">
        {title}
      </h4>
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

type ClientFilter = "all" | "Claude Code" | "Gemini CLI" | "Codex CLI";
type StatusFilter = "all" | "active" | "completed" | "interrupted";

export function SessionsTab() {
  const { selectedBarrack } = useAppStore();
  const [sessions, setSessions] = useState<SessionInfo[]>([]);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [details, setDetails] = useState<Record<string, SessionDetail>>({});
  const [clientFilter, setClientFilter] = useState<ClientFilter>("all");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("active");

  const loadSessions = useCallback(async () => {
    if (!selectedBarrack) return;
    try {
      const result = await invoke<SessionInfo[]>("get_sessions", {
        barrackPath: selectedBarrack.path,
      });
      setSessions(result);
    } catch (e) {
      console.error("Failed to load sessions:", e);
    }
  }, [selectedBarrack]);

  useEffect(() => {
    loadSessions();
    // Auto-refresh when session files change
    const unlisten = listen("file-changed", () => {
      loadSessions();
    });
    return () => { unlisten.then((fn) => fn()); };
  }, [loadSessions]);

  const handleToggle = async (id: string) => {
    if (expandedId === id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(id);
    if (!details[id] && selectedBarrack) {
      try {
        const detail = await invoke<SessionDetail>("get_session_detail", {
          barrackPath: selectedBarrack.path,
          sessionId: id,
        });
        setDetails((prev) => ({ ...prev, [id]: detail }));
      } catch (e) {
        console.error("Failed to load session detail:", e);
      }
    }
  };

  const handleContinue = async (session: SessionInfo) => {
    if (!selectedBarrack) return;
    const clientKey = session.client.toLowerCase().split(" ")[0]; // "Claude Code" → "claude"
    try {
      const cmd = await invoke<LaunchCommand>("get_continue_command", {
        barrackPath: selectedBarrack.path,
        client: clientKey,
        sessionId: session.id,
        skipPermissions: false,
      });
      const termStore = useTerminalStore.getState();
      termStore.addSession({
        id: crypto.randomUUID(),
        title: `${session.client.split(" ")[0]} - Continue ${session.id}`,
        barrackPath: selectedBarrack.path,
        client: clientKey,
        cwd: cmd.cwd,
        initialCommand: cmd.command,
      });
    } catch (e) {
      alert(`Continue 실패: ${e}`);
    }
  };

  const filtered = sessions.filter((s) => {
    if (clientFilter !== "all" && s.client !== clientFilter) return false;
    if (statusFilter !== "all" && s.status !== statusFilter) return false;
    return true;
  });

  return (
    <div className="p-5 max-w-4xl">
      {/* Filters */}
      <div className="flex items-center gap-6 mb-4">
        <div className="flex items-center gap-1">
          {(["all", "active", "completed", "interrupted"] as const).map((f) => (
            <button
              key={f}
              onClick={() => setStatusFilter(f)}
              className={`text-[12px] px-2.5 py-1 rounded-md transition-colors ${
                statusFilter === f
                  ? "bg-cc-panel text-cc-text font-medium shadow-cc"
                  : "text-cc-text-muted hover:text-cc-text-dim"
              }`}
            >
              {f.charAt(0).toUpperCase() + f.slice(1)}
            </button>
          ))}
        </div>
        <div className="h-4 w-px bg-cc-border" />
        <div className="flex items-center gap-1">
          {(["all", "Claude Code", "Gemini CLI", "Codex CLI"] as const).map(
            (f) => (
              <button
                key={f}
                onClick={() => setClientFilter(f)}
                className={`text-[12px] px-2.5 py-1 rounded-md transition-colors ${
                  clientFilter === f
                    ? "bg-cc-panel text-cc-text font-medium shadow-cc"
                    : "text-cc-text-muted hover:text-cc-text-dim"
                }`}
              >
                {f === "all" ? "All" : f.split(" ")[0]}
              </button>
            ),
          )}
        </div>
        <span className="flex-1" />
        <span className="text-[11px] text-cc-text-muted">
          {filtered.length} / {sessions.length}
        </span>
      </div>

      {/* Agent list */}
      <div className="space-y-1.5">
        {filtered.map((session) => (
          <SessionCard
            key={session.id}
            session={session}
            isExpanded={expandedId === session.id}
            onToggle={() => handleToggle(session.id)}
            onContinue={() => handleContinue(session)}
            onViewInTerminal={() => {
              if (!selectedBarrack) return;
              const sessionFile = `${selectedBarrack.path}/sessions/${session.id}.md`;
              const violationFile = `${selectedBarrack.path}/sessions/${session.id}.violations`;
              useTerminalStore.getState().addSession({
                id: crypto.randomUUID(),
                title: `Session - ${session.id}`,
                cwd: selectedBarrack.path,
                initialCommand: `cat '${sessionFile}' && [ -f '${violationFile}' ] && echo '\\n=== VIOLATIONS ===' && cat '${violationFile}' || true`,
              });
            }}
            onMonitor={() => {
              if (!selectedBarrack) return;
              const sessionFile = `${selectedBarrack.path}/sessions/${session.id}.md`;
              useTerminalStore.getState().addSession({
                id: crypto.randomUUID(),
                title: `Monitor - ${session.id}`,
                cwd: selectedBarrack.path,
                initialCommand: `echo '=== Monitoring ${session.id} ===' && echo 'Refreshes every 3s. Ctrl+C to stop.' && echo '' && while true; do clear; echo '=== ${session.id} ===' && tail -30 '${sessionFile}'; sleep 3; done`,
              });
            }}
            detail={details[session.id] ?? null}
          />
        ))}
      </div>

      {filtered.length === 0 && (
        <div className="text-center text-cc-text-muted py-12">
          {sessions.length === 0
            ? "에이전트 기록이 없습니다"
            : "필터 조건에 맞는 에이전트가 없습니다"}
        </div>
      )}
    </div>
  );
}
