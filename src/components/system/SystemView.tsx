import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { useTerminalStore } from "../../stores/terminalStore";
import type { SyncResult } from "../../types";

export function SystemView() {
  const { barracks, cliVersion, fetchBarracks } = useAppStore();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [syncing, setSyncing] = useState(false);
  const [dryRun, setDryRun] = useState(false);
  const [results, setResults] = useState<SyncResult[] | null>(null);
  const [creating, setCreating] = useState(false);
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null);
  const [newPath, setNewPath] = useState("");
  const [createOutput, setCreateOutput] = useState<string | null>(null);

  const outdated = barracks.filter((b) => b.aib_version !== cliVersion);
  const allSelected = barracks.length > 0 && selected.size === barracks.length;

  const toggleSelect = (path: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };

  const toggleAll = () => {
    if (allSelected) {
      setSelected(new Set());
    } else {
      setSelected(new Set(barracks.map((b) => b.path)));
    }
  };

  const selectOutdated = () => {
    setSelected(new Set(outdated.map((b) => b.path)));
  };

  const handleSync = async () => {
    if (selected.size === 0) return;
    setSyncing(true);
    setResults(null);
    try {
      const res = await invoke<SyncResult[]>("sync_all_barracks", {
        paths: Array.from(selected),
        dryRun,
      });
      setResults(res);
      if (!dryRun) {
        await fetchBarracks();
      }
    } catch (e) {
      setResults([{ path: "error", success: false, output: String(e) }]);
    } finally {
      setSyncing(false);
    }
  };

  const handleCreate = async () => {
    if (!newPath.trim()) return;
    setCreating(true);
    setCreateOutput(null);
    try {
      const output = await invoke<string>("create_barrack", {
        path: newPath.trim(),
      });
      setCreateOutput(output);
      setNewPath("");
      await fetchBarracks();
    } catch (e) {
      setCreateOutput(`Error: ${e}`);
    } finally {
      setCreating(false);
    }
  };

  return (
    <div className="flex-1 flex flex-col overflow-hidden bg-cc-bg">
      <div className="flex items-center border-b border-cc-border px-4 h-10 shrink-0">
        <span className="text-[13px] font-medium text-cc-text">System</span>
      </div>

      <div className="flex-1 overflow-y-auto p-5 max-w-4xl">
        {/* Version Dashboard */}
        <div className="mb-8">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-[15px] font-semibold">Version & Sync</h2>
            <span className="text-[12px] text-cc-text-muted">
              CLI v{cliVersion}
              {outdated.length > 0 && (
                <span className="text-cc-warning ml-2">
                  {outdated.length} outdated
                </span>
              )}
            </span>
          </div>

          {/* Action bar */}
          <div className="flex items-center gap-3 mb-3">
            <button
              onClick={handleSync}
              disabled={syncing || selected.size === 0}
              className="text-[12px] px-3 py-1.5 bg-cc-accent text-white rounded-md hover:bg-cc-accent-dim transition-colors disabled:opacity-40"
            >
              {syncing
                ? "Syncing..."
                : `Sync ${selected.size > 0 ? `(${selected.size})` : ""}`}
            </button>
            <button
              onClick={() => {
                if (selected.size === 0) return;
                const aib = "/opt/homebrew/bin/aib";
                const paths = Array.from(selected);
                const syncCmd = paths.map((p) => {
                  const name = p.split("/").pop();
                  return `echo '\\n=== ${name} ===' && ${aib} sync '${p}'`;
                }).join(" && ");
                useTerminalStore.getState().addSession({
                  id: crypto.randomUUID(),
                  title: `Sync ${paths.length} barracks`,
                  initialCommand: syncCmd,
                });
              }}
              disabled={selected.size === 0}
              className="text-[12px] px-3 py-1.5 bg-cc-panel border border-cc-border rounded-md hover:border-cc-accent/40 transition-colors text-cc-text-dim disabled:opacity-40"
            >
              Sync in Terminal
            </button>
            {outdated.length > 0 && (
              <button
                onClick={selectOutdated}
                className="text-[12px] px-3 py-1.5 bg-cc-panel border border-cc-border rounded-md hover:border-cc-accent/40 transition-colors text-cc-text-dim"
              >
                Select outdated
              </button>
            )}
            <label className="flex items-center gap-1.5 text-[12px] text-cc-text-dim cursor-pointer select-none">
              <input
                type="checkbox"
                checked={dryRun}
                onChange={(e) => setDryRun(e.target.checked)}
                className="w-3.5 h-3.5 accent-cc-accent"
              />
              Dry-run
            </label>
          </div>

          {/* Barrack table */}
          <div className="border border-cc-border rounded-lg overflow-hidden shadow-cc">
            <table className="w-full text-[13px]">
              <thead>
                <tr className="bg-cc-panel/50 text-cc-text-muted text-left text-[11px] uppercase tracking-wider">
                  <th className="px-3 py-2 w-8">
                    <input
                      type="checkbox"
                      checked={allSelected}
                      onChange={toggleAll}
                      className="w-3.5 h-3.5 accent-cc-accent"
                    />
                  </th>
                  <th className="px-3 py-2">Barrack</th>
                  <th className="px-3 py-2 w-24">Version</th>
                  <th className="px-3 py-2 w-24">Status</th>
                  <th className="px-3 py-2 w-16"></th>
                </tr>
              </thead>
              <tbody>
                {barracks.map((b) => {
                  const isOutdated = b.aib_version !== cliVersion;
                  return (
                    <tr
                      key={b.path}
                      className="border-t border-cc-border hover:bg-cc-card-hover transition-colors"
                    >
                      <td className="px-3 py-2.5">
                        <input
                          type="checkbox"
                          checked={selected.has(b.path)}
                          onChange={() => toggleSelect(b.path)}
                          className="w-3.5 h-3.5 accent-cc-accent"
                        />
                      </td>
                      <td className="px-3 py-2.5">
                        <div className="font-medium">{b.name}</div>
                        <div className="text-[11px] text-cc-text-muted truncate max-w-[300px]">
                          {b.path}
                        </div>
                      </td>
                      <td className="px-3 py-2.5 font-mono text-[12px]">
                        v{b.aib_version}
                      </td>
                      <td className="px-3 py-2.5">
                        <span
                          className={`text-[11px] px-2 py-0.5 rounded font-medium ${
                            isOutdated
                              ? "bg-cc-warning/15 text-cc-warning"
                              : "bg-cc-success/15 text-cc-success"
                          }`}
                        >
                          {isOutdated ? "Outdated" : "Up to date"}
                        </span>
                      </td>
                      <td className="px-3 py-2.5">
                        {confirmRemove === b.path ? (
                          <div className="flex items-center gap-1">
                            <button
                              onClick={async () => {
                                try {
                                  await invoke<string>("remove_barrack", { path: b.path });
                                  setConfirmRemove(null);
                                  await fetchBarracks();
                                } catch (e) {
                                  setResults([{ path: b.path, success: false, output: String(e) }]);
                                  setConfirmRemove(null);
                                }
                              }}
                              className="text-[11px] text-cc-danger font-medium"
                            >
                              Yes
                            </button>
                            <button
                              onClick={() => setConfirmRemove(null)}
                              className="text-[11px] text-cc-text-muted"
                            >
                              No
                            </button>
                          </div>
                        ) : (
                          <button
                            onClick={() => setConfirmRemove(b.path)}
                            className="text-[11px] text-cc-text-muted hover:text-cc-danger transition-colors"
                          >
                            Remove
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {/* Sync results */}
          {results && (
            <div className="mt-3 border border-cc-border rounded-lg overflow-hidden shadow-cc">
              <div className="px-3 py-2 bg-cc-panel/50 text-[11px] text-cc-text-muted uppercase tracking-wider font-medium">
                {dryRun ? "Dry-run Results" : "Sync Results"}
              </div>
              {results.map((r, i) => (
                <div
                  key={i}
                  className="px-3 py-2 border-t border-cc-border text-[12px]"
                >
                  <div className="flex items-center gap-2 mb-1">
                    <span
                      className={
                        r.success ? "text-cc-success" : "text-cc-danger"
                      }
                    >
                      {r.success ? "✓" : "✗"}
                    </span>
                    <span className="text-cc-text-dim font-medium">
                      {r.path.split("/").pop()}
                    </span>
                  </div>
                  <pre className="text-[11px] text-cc-text-muted whitespace-pre-wrap font-mono leading-relaxed">
                    {r.output.trim()}
                  </pre>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Create Barrack */}
        <div>
          <h2 className="text-[15px] font-semibold mb-3">New Barrack</h2>
          <div className="flex items-center gap-2">
            <input
              type="text"
              value={newPath}
              onChange={(e) => setNewPath(e.target.value)}
              placeholder="/path/to/new/barrack"
              className="flex-1 text-[13px] px-3 py-1.5 bg-cc-panel border border-cc-border rounded-md text-cc-text placeholder:text-cc-text-muted focus:outline-none focus:border-cc-accent/50"
            />
            <button
              onClick={handleCreate}
              disabled={creating || !newPath.trim()}
              className="text-[12px] px-4 py-1.5 bg-cc-accent text-white rounded-md hover:bg-cc-accent-dim transition-colors disabled:opacity-40"
            >
              {creating ? "Creating..." : "Create"}
            </button>
          </div>
          {createOutput && (
            <pre className="mt-2 text-[11px] text-cc-text-muted whitespace-pre-wrap font-mono p-3 bg-cc-panel border border-cc-border rounded-md">
              {createOutput.trim()}
            </pre>
          )}
        </div>
      </div>
    </div>
  );
}
