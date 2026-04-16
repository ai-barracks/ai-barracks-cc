import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useAppStore } from "../../stores/appStore";
import { useTerminalStore } from "../../stores/terminalStore";
import { SessionCard } from "./SessionCard";
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
  const [launching, setLaunching] = useState(false);
  const [skipPermissions, setSkipPermissions] = useState(false);

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
    // Polling fallback: FSEvents on macOS can miss file creation events
    const poll = setInterval(loadSessions, 5000);
    return () => {
      unlisten.then((fn) => fn());
      clearInterval(poll);
    };
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

  // --- Agent launch ---
  const handleLaunch = async (client: string) => {
    if (!selectedBarrack) return;
    setLaunching(true);
    try {
      const cmd = await invoke<LaunchCommand>("get_launch_command", {
        barrackPath: selectedBarrack.path,
        client,
        skipPermissions,
      });
      useTerminalStore.getState().addSession({
        id: crypto.randomUUID(),
        title: `${client.charAt(0).toUpperCase() + client.slice(1)} - ${selectedBarrack.name}`,
        barrackPath: selectedBarrack.path,
        client,
        cwd: cmd.cwd,
        initialCommand: cmd.command,
        source: "launch",
      });
    } catch (e) {
      alert(`세션 실행 실패: ${e}`);
    } finally {
      setLaunching(false);
    }
  };

  // --- Session actions → terminal store ---
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
      useTerminalStore.getState().addSession({
        id: crypto.randomUUID(),
        title: `${session.client.split(" ")[0]} - ${session.id.slice(0, 8)}`,
        barrackPath: selectedBarrack.path,
        client: clientKey,
        cwd: cmd.cwd,
        initialCommand: cmd.command,
        source: "continue",
      });
    } catch (e) {
      alert(`Continue 실패: ${e}`);
    }
  };

  const handleViewInTerminal = (session: SessionInfo) => {
    if (!selectedBarrack) return;
    const sessionFile = `${selectedBarrack.path}/sessions/${session.id}.md`;
    const violationFile = `${selectedBarrack.path}/sessions/${session.id}.violations`;
    useTerminalStore.getState().addSession({
      id: crypto.randomUUID(),
      title: `View - ${session.id.slice(0, 8)}`,
      barrackPath: selectedBarrack.path,
      cwd: selectedBarrack.path,
      initialCommand: `cat '${sessionFile}' && [ -f '${violationFile}' ] && echo '\\n=== VIOLATIONS ===' && cat '${violationFile}' || true`,
      source: "view",
      autoCloseOnExit: true,
    });
  };

  const handleMonitor = (session: SessionInfo) => {
    if (!selectedBarrack) return;
    const sessionFile = `${selectedBarrack.path}/sessions/${session.id}.md`;
    useTerminalStore.getState().addSession({
      id: crypto.randomUUID(),
      title: `Monitor - ${session.id.slice(0, 8)}`,
      barrackPath: selectedBarrack.path,
      cwd: selectedBarrack.path,
      initialCommand: `echo '=== Monitoring ${session.id} ===' && echo 'Refreshes every 3s. Ctrl+C to stop.' && echo '' && while true; do clear; echo '=== ${session.id} ===' && tail -30 '${sessionFile}'; sleep 3; done`,
      source: "monitor",
    });
  };

  const filtered = sessions.filter((s) => {
    if (clientFilter !== "all" && s.client !== clientFilter) return false;
    if (statusFilter !== "all" && s.status !== statusFilter) return false;
    if (hidePending && s.status !== "active" && (!s.task || s.task === "(pending)")) return false;
    return true;
  });

  return (
    <div className="flex-1 overflow-y-auto min-w-0">
      <div className="p-5 max-w-4xl">
        {/* New Agent bar */}
        <div className="mb-5 p-3 bg-cc-panel border border-cc-border rounded-lg">
          <div className="flex items-center gap-3">
            <span className="text-xs font-medium text-cc-text-muted uppercase tracking-wider">New Agent</span>
            <div className="flex gap-2">
              {["claude", "gemini", "codex"].map((client) => (
                <button
                  key={client}
                  onClick={() => handleLaunch(client)}
                  disabled={launching}
                  className="px-3 py-1.5 text-xs bg-cc-bg border border-cc-border rounded-md hover:border-cc-accent/40 hover:bg-cc-accent/10 transition-colors disabled:opacity-50"
                >
                  {client.charAt(0).toUpperCase() + client.slice(1)}
                </button>
              ))}
            </div>
            <div className="h-4 w-px bg-cc-border" />
            <button
              onClick={() => {
                if (!selectedBarrack) return;
                useTerminalStore.getState().addSession({
                  id: crypto.randomUUID(),
                  title: selectedBarrack.name,
                  barrackPath: selectedBarrack.path,
                  cwd: selectedBarrack.path,
                  initialCommand: "/opt/homebrew/bin/aib status",
                  source: "terminal",
                });
              }}
              className="px-3 py-1.5 text-xs bg-cc-bg border border-cc-border rounded-md hover:border-cc-accent/40 hover:bg-cc-accent/10 transition-colors"
            >
              Terminal
            </button>
            <button
              onClick={() => {
                if (!selectedBarrack) return;
                const topic = prompt("Council 토론 주제를 입력하세요:");
                if (topic) {
                  useTerminalStore.getState().addSession({
                    id: crypto.randomUUID(),
                    title: `Council - ${topic.slice(0, 20)}`,
                    barrackPath: selectedBarrack.path,
                    cwd: selectedBarrack.path,
                    initialCommand: `/opt/homebrew/bin/aib council "${topic}"`,
                    source: "council",
                  });
                }
              }}
              className="px-3 py-1.5 text-xs bg-cc-bg border border-cc-border rounded-md hover:border-cc-accent/40 hover:bg-cc-accent/10 transition-colors"
            >
              Council
            </button>
            <span className="flex-1" />
            <label className="flex items-center gap-1.5 text-xs text-cc-text-dim cursor-pointer select-none">
              <input
                type="checkbox"
                checked={skipPermissions}
                onChange={(e) => setSkipPermissions(e.target.checked)}
                className="rounded border-cc-border bg-cc-panel text-cc-accent w-3.5 h-3.5 accent-cc-accent"
              />
              skip-permissions
            </label>
          </div>
        </div>

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

        {/* Session cards */}
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
  );
}
