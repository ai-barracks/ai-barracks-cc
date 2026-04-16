import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { useTerminalStore } from "../../stores/terminalStore";
import type { GitStatus, GitLogEntry } from "../../types";

function RemoteLink({ url }: { url: string }) {
  if (!url) return null;
  // Convert git URL to browser URL
  const browserUrl = url
    .replace(/\.git$/, "")
    .replace(/^git@github\.com:/, "https://github.com/")
    .replace(/^git@gitlab\.com:/, "https://gitlab.com/");

  return (
    <a
      href={browserUrl}
      target="_blank"
      rel="noopener noreferrer"
      className="text-[12px] text-cc-accent hover:underline truncate"
    >
      {browserUrl}
    </a>
  );
}

export function GitTab() {
  const { selectedBarrack } = useAppStore();
  const addTerminal = useTerminalStore((s) => s.addSession);
  const [status, setStatus] = useState<GitStatus | null>(null);
  const [log, setLog] = useState<GitLogEntry[]>([]);
  const [commitMsg, setCommitMsg] = useState("");
  const [committing, setCommitting] = useState(false);
  const [pushing, setPushing] = useState(false);
  const [actionResult, setActionResult] = useState<{
    type: "success" | "error";
    msg: string;
  } | null>(null);

  const loadGit = useCallback(async () => {
    if (!selectedBarrack) return;
    try {
      const [s, l] = await Promise.all([
        invoke<GitStatus>("get_git_status", {
          barrackPath: selectedBarrack.path,
        }),
        invoke<GitLogEntry[]>("get_git_log", {
          barrackPath: selectedBarrack.path,
          count: 20,
        }).catch(() => [] as GitLogEntry[]),
      ]);
      setStatus(s);
      setLog(l);
    } catch (e) {
      console.error("Failed to load git status:", e);
    }
  }, [selectedBarrack]);

  useEffect(() => {
    loadGit();
  }, [loadGit]);

  const handleCommit = async () => {
    if (!selectedBarrack || !commitMsg.trim()) return;
    setCommitting(true);
    setActionResult(null);
    try {
      const result = await invoke<string>("git_commit", {
        barrackPath: selectedBarrack.path,
        message: commitMsg.trim(),
      });
      setActionResult({ type: "success", msg: result });
      setCommitMsg("");
      await loadGit();
    } catch (e) {
      setActionResult({ type: "error", msg: String(e) });
    } finally {
      setCommitting(false);
    }
  };

  const handlePush = async () => {
    if (!selectedBarrack) return;
    setPushing(true);
    setActionResult(null);
    try {
      const result = await invoke<string>("git_push", {
        barrackPath: selectedBarrack.path,
      });
      setActionResult({ type: "success", msg: result || "Push complete" });
      await loadGit();
    } catch (e) {
      setActionResult({ type: "error", msg: String(e) });
    } finally {
      setPushing(false);
    }
  };

  if (!status) return null;

  if (!status.is_repo) {
    return (
      <div className="p-5 max-w-4xl">
        <p className="text-cc-text-muted text-[13px]">
          이 배럭은 Git 저장소가 아닙니다.
        </p>
      </div>
    );
  }

  const totalChanges =
    status.changed_files + status.untracked_files + status.staged_files;

  return (
    <div className="p-5 max-w-4xl">
      {/* Sub-path notice */}
      {status.is_sub_path && (
        <div className="mb-4 px-3 py-2 bg-cc-warning/10 border border-cc-warning/20 rounded-lg text-[12px] text-cc-warning">
          이 배럭은 상위 저장소의 일부입니다. 아래 정보는 이 배럭 하위 파일만 표시합니다.
          <span className="text-cc-text-muted ml-2">root: {status.git_root}</span>
        </div>
      )}

      {/* Status overview */}
      <div className="grid grid-cols-3 gap-3 mb-6">
        <div className="bg-cc-panel border border-cc-border rounded-lg p-4 shadow-cc">
          <div className="text-[11px] text-cc-text-muted uppercase tracking-wider mb-1">
            Branch
          </div>
          <div className="text-[15px] font-semibold">{status.branch}</div>
          {(status.ahead > 0 || status.behind > 0) && (
            <div className="text-[11px] text-cc-text-muted mt-1">
              {status.ahead > 0 && (
                <span className="text-cc-success mr-2">
                  {status.ahead} ahead
                </span>
              )}
              {status.behind > 0 && (
                <span className="text-cc-warning">
                  {status.behind} behind
                </span>
              )}
            </div>
          )}
        </div>

        <button
          onClick={() => {
            if (totalChanges > 0 && selectedBarrack) {
              addTerminal({
                id: crypto.randomUUID(),
                title: `diff - ${selectedBarrack.name}`,
                barrackPath: selectedBarrack.path,
                cwd: status.git_root || selectedBarrack.path,
                initialCommand: "git diff --stat && echo '---' && git diff",
                source: "terminal",
                autoCloseOnExit: true,
              });
            }
          }}
          disabled={totalChanges === 0}
          className="bg-cc-panel border border-cc-border rounded-lg p-4 shadow-cc text-left hover:border-cc-accent/40 transition-colors disabled:cursor-default"
        >
          <div className="text-[11px] text-cc-text-muted uppercase tracking-wider mb-1">
            Changes
          </div>
          <div className="text-[15px] font-semibold">
            {totalChanges === 0 ? (
              <span className="text-cc-success">Clean</span>
            ) : (
              totalChanges
            )}
          </div>
          {totalChanges > 0 && (
            <div className="text-[11px] text-cc-text-muted mt-1">
              {status.staged_files > 0 && (
                <span className="text-cc-success mr-2">
                  {status.staged_files} staged
                </span>
              )}
              {status.changed_files > 0 && (
                <span className="text-cc-warning mr-2">
                  {status.changed_files} modified
                </span>
              )}
              {status.untracked_files > 0 && (
                <span className="text-cc-text-muted">
                  {status.untracked_files} untracked
                </span>
              )}
              <div className="text-[10px] text-cc-accent mt-1">Click to view diff</div>
            </div>
          )}
        </button>

        <div className="bg-cc-panel border border-cc-border rounded-lg p-4 shadow-cc">
          <div className="text-[11px] text-cc-text-muted uppercase tracking-wider mb-1">
            Remote
          </div>
          {status.remote_url ? (
            <RemoteLink url={status.remote_url} />
          ) : (
            <span className="text-[13px] text-cc-text-muted">No remote</span>
          )}
        </div>
      </div>

      {/* Commit + Push */}
      {totalChanges > 0 && (
        <div className="mb-6">
          <h3 className="text-[11px] text-cc-text-muted uppercase tracking-wider mb-2 font-medium">
            Commit
          </h3>
          <div className="flex items-center gap-2">
            <input
              type="text"
              value={commitMsg}
              onChange={(e) => setCommitMsg(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handleCommit()}
              placeholder="Commit message..."
              className="flex-1 text-[13px] px-3 py-1.5 bg-cc-panel border border-cc-border rounded-md text-cc-text placeholder:text-cc-text-muted focus:outline-none focus:border-cc-accent/50"
            />
            <button
              onClick={handleCommit}
              disabled={committing || !commitMsg.trim()}
              className="text-[12px] px-4 py-1.5 bg-cc-accent text-white rounded-md hover:bg-cc-accent-dim transition-colors disabled:opacity-40"
            >
              {committing ? "Committing..." : "Commit"}
            </button>
          </div>
        </div>
      )}

      {/* Push */}
      {status.ahead > 0 && (
        <div className="mb-6">
          <button
            onClick={handlePush}
            disabled={pushing}
            className="text-[12px] px-4 py-1.5 bg-cc-success/15 text-cc-success border border-cc-success/20 rounded-md hover:bg-cc-success/25 transition-colors disabled:opacity-40"
          >
            {pushing
              ? "Pushing..."
              : `Push ${status.ahead} commit${status.ahead > 1 ? "s" : ""}`}
          </button>
        </div>
      )}

      {/* Action result */}
      {actionResult && (
        <div
          className={`mb-6 text-[12px] px-3 py-2 rounded-md border ${
            actionResult.type === "success"
              ? "bg-cc-success/10 border-cc-success/20 text-cc-success"
              : "bg-cc-danger/10 border-cc-danger/20 text-cc-danger"
          }`}
        >
          <pre className="whitespace-pre-wrap font-mono">
            {actionResult.msg}
          </pre>
        </div>
      )}

      {/* Last commit */}
      {status.last_commit && (
        <div className="mb-6 text-[12px] text-cc-text-dim">
          <span className="text-cc-text-muted">Last commit: </span>
          {status.last_commit}
          <span className="text-cc-text-muted ml-2">
            ({status.last_commit_time})
          </span>
        </div>
      )}

      {/* Interactive Git Actions */}
      <div className="mb-6">
        <h3 className="text-[11px] text-cc-text-muted uppercase tracking-wider mb-2 font-medium">
          Terminal Actions
        </h3>
        <div className="flex flex-wrap gap-2">
          <button
            onClick={() => {
              if (selectedBarrack) {
                addTerminal({
                  id: crypto.randomUUID(),
                  title: `git status - ${selectedBarrack.name}`,
                  barrackPath: selectedBarrack.path,
                  cwd: status.git_root || selectedBarrack.path,
                  initialCommand: "git status",
                  source: "terminal",
                  autoCloseOnExit: true,
                });
              }
            }}
            className="text-[11px] px-2.5 py-1 bg-cc-panel border border-cc-border rounded hover:border-cc-accent/40 transition-colors text-cc-text-dim"
          >
            git status
          </button>
          {totalChanges > 0 && (
            <button
              onClick={() => {
                if (selectedBarrack) {
                  addTerminal({
                    id: crypto.randomUUID(),
                    title: `git add -p`,
                    barrackPath: selectedBarrack.path,
                    cwd: status.git_root || selectedBarrack.path,
                    initialCommand: "git add -p",
                    source: "terminal",
                  });
                }
              }}
              className="text-[11px] px-2.5 py-1 bg-cc-panel border border-cc-border rounded hover:border-cc-accent/40 transition-colors text-cc-text-dim"
            >
              git add -p
            </button>
          )}
          <button
            onClick={() => {
              if (selectedBarrack) {
                addTerminal({
                  id: crypto.randomUUID(),
                  title: `git graph`,
                  barrackPath: selectedBarrack.path,
                  cwd: status.git_root || selectedBarrack.path,
                  initialCommand: "git log --graph --oneline --all -20",
                  source: "terminal",
                  autoCloseOnExit: true,
                });
              }
            }}
            className="text-[11px] px-2.5 py-1 bg-cc-panel border border-cc-border rounded hover:border-cc-accent/40 transition-colors text-cc-text-dim"
          >
            git graph
          </button>
          <button
            onClick={() => {
              if (selectedBarrack) {
                addTerminal({
                  id: crypto.randomUUID(),
                  title: `git stash`,
                  barrackPath: selectedBarrack.path,
                  cwd: status.git_root || selectedBarrack.path,
                  initialCommand: "git stash list",
                  source: "terminal",
                  autoCloseOnExit: true,
                });
              }
            }}
            className="text-[11px] px-2.5 py-1 bg-cc-panel border border-cc-border rounded hover:border-cc-accent/40 transition-colors text-cc-text-dim"
          >
            git stash
          </button>
        </div>
      </div>

      {/* Log */}
      <div>
        <h3 className="text-[11px] text-cc-text-muted uppercase tracking-wider mb-2 font-medium">
          History
        </h3>
        <div className="border border-cc-border rounded-lg overflow-hidden shadow-cc">
          {log.map((entry) => (
            <button
              key={entry.hash}
              onClick={() => {
                if (selectedBarrack) {
                  addTerminal({
                    id: crypto.randomUUID(),
                    title: `${entry.hash} - ${entry.message.slice(0, 20)}`,
                    barrackPath: selectedBarrack.path,
                    cwd: status.git_root || selectedBarrack.path,
                    initialCommand: `git show ${entry.hash}`,
                    source: "view",
                    autoCloseOnExit: true,
                  });
                }
              }}
              className="flex items-center gap-3 px-4 py-2 border-b border-cc-border last:border-0 hover:bg-cc-card-hover transition-colors w-full text-left"
            >
              <span className="text-[11px] font-mono text-cc-accent w-14 shrink-0">
                {entry.hash}
              </span>
              <span className="text-[13px] text-cc-text truncate flex-1">
                {entry.message}
              </span>
              <span className="text-[11px] text-cc-text-muted shrink-0">
                {entry.date}
              </span>
            </button>
          ))}
          {log.length === 0 && (
            <div className="px-4 py-6 text-center text-[12px] text-cc-text-muted">
              No commits yet
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
