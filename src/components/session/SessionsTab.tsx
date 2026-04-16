import { useEffect, useState, useCallback, useReducer } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useAppStore } from "../../stores/appStore";
import { SessionCard } from "./SessionCard";
import { EmbeddedTerminalPanel } from "./EmbeddedTerminalPanel";
import {
  embeddedTerminalReducer,
  INITIAL_EMBEDDED_STATE,
} from "./embeddedTerminalReducer";
import type { SessionInfo, SessionDetail, LaunchCommand } from "../../types";

type ClientFilter = "all" | "Claude Code" | "Gemini CLI" | "Codex CLI";
type StatusFilter = "all" | "active" | "completed" | "interrupted";

export function SessionsTab() {
  const { selectedBarrack } = useAppStore();
  const [sessions, setSessions] = useState<SessionInfo[]>([]);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [details, setDetails] = useState<Record<string, SessionDetail>>({});
  const [clientFilter, setClientFilter] = useState<ClientFilter>("all");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("active");
  const [hidePending, setHidePending] = useState(true);
  const [terminalState, dispatch] = useReducer(embeddedTerminalReducer, INITIAL_EMBEDDED_STATE);

  // 배럭 전환 시 임베디드 터미널 초기화
  useEffect(() => {
    dispatch({ type: "RESET" });
  }, [selectedBarrack?.path]);

  const loadSessions = useCallback(async () => {
    if (!selectedBarrack) return;
    try {
      const result = await invoke<SessionInfo[]>("get_sessions", {
        barrackPath: selectedBarrack.path,
      });
      setSessions(result);
    } catch {
      // ignore
    }
  }, [selectedBarrack]);

  useEffect(() => {
    loadSessions();
    const unlisten = listen("file-changed", () => loadSessions());
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
      } catch {
        // ignore
      }
    }
  };

  const handleContinue = async (session: SessionInfo) => {
    if (!selectedBarrack) return;
    const clientKey = session.client.toLowerCase().split(" ")[0];
    try {
      const cmd = await invoke<LaunchCommand>("get_continue_command", {
        barrackPath: selectedBarrack.path,
        client: clientKey,
        sessionId: session.id,
        skipPermissions: false,
      });
      dispatch({
        type: "ADD_SESSION",
        session: {
          id: crypto.randomUUID(),
          title: `${session.client.split(" ")[0]} - ${session.id.slice(0, 8)}`,
          cwd: cmd.cwd,
          initialCommand: cmd.command,
        },
      });
    } catch (e) {
      alert(`Continue 실패: ${e}`);
    }
  };

  const handleViewInTerminal = (session: SessionInfo) => {
    if (!selectedBarrack) return;
    const sessionFile = `${selectedBarrack.path}/sessions/${session.id}.md`;
    const violationFile = `${selectedBarrack.path}/sessions/${session.id}.violations`;
    dispatch({
      type: "ADD_SESSION",
      session: {
        id: crypto.randomUUID(),
        title: `View - ${session.id.slice(0, 8)}`,
        cwd: selectedBarrack.path,
        initialCommand: `cat '${sessionFile}' && [ -f '${violationFile}' ] && echo '\\n=== VIOLATIONS ===' && cat '${violationFile}' || true`,
      },
    });
  };

  const handleMonitor = (session: SessionInfo) => {
    if (!selectedBarrack) return;
    const sessionFile = `${selectedBarrack.path}/sessions/${session.id}.md`;
    dispatch({
      type: "ADD_SESSION",
      session: {
        id: crypto.randomUUID(),
        title: `Monitor - ${session.id.slice(0, 8)}`,
        cwd: selectedBarrack.path,
        initialCommand: `echo '=== Monitoring ${session.id} ===' && echo 'Refreshes every 3s. Ctrl+C to stop.' && echo '' && while true; do clear; echo '=== ${session.id} ===' && tail -30 '${sessionFile}'; sleep 3; done`,
      },
    });
  };

  const filtered = sessions.filter((s) => {
    if (clientFilter !== "all" && s.client !== clientFilter) return false;
    if (statusFilter !== "all" && s.status !== statusFilter) return false;
    if (hidePending && (!s.task || s.task === "(pending)")) return false;
    return true;
  });

  return (
    <div className="flex h-full overflow-hidden">
      {/* 좌: 에이전트 목록 */}
      <div className="flex-1 overflow-y-auto min-w-0">
        <div className="p-5 max-w-2xl">
          {/* 필터 */}
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
              {(["all", "Claude Code", "Gemini CLI", "Codex CLI"] as const).map((f) => (
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
              ))}
            </div>
            <span className="flex-1" />
            <button
              onClick={() => setHidePending((v) => !v)}
              className={`text-[11px] px-2 py-0.5 rounded transition-colors ${
                hidePending
                  ? "text-cc-text-muted hover:text-cc-text-dim"
                  : "bg-cc-warning/20 text-cc-warning"
              }`}
              title={hidePending ? "빈 세션 포함 표시" : "빈 세션 숨기기"}
            >
              {hidePending ? "empty 숨김" : "empty 표시"}
            </button>
            <span className="text-[11px] text-cc-text-muted">
              {filtered.length} / {sessions.length}
            </span>
          </div>

          {/* 세션 카드 목록 */}
          <div className="space-y-1.5">
            {filtered.map((session) => (
              <SessionCard
                key={session.id}
                session={session}
                isExpanded={expandedId === session.id}
                detail={details[session.id] ?? null}
                onToggle={() => handleToggle(session.id)}
                onContinue={() => handleContinue(session)}
                onViewInTerminal={() => handleViewInTerminal(session)}
                onMonitor={() => handleMonitor(session)}
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
      </div>

      {/* 우: 임베디드 터미널 */}
      {terminalState.isExpanded ? (
        <EmbeddedTerminalPanel state={terminalState} dispatch={dispatch} />
      ) : (
        <div
          className="w-7 flex flex-col items-center justify-center py-3 text-xs text-cc-text-muted bg-cc-sidebar border-l border-cc-border flex-shrink-0"
          style={{ writingMode: "vertical-rl" }}
        >
          Agent Terminal
        </div>
      )}
    </div>
  );
}
