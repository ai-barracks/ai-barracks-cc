import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";

function StatCard({
  label,
  value,
  sub,
}: {
  label: string;
  value: string | number;
  sub?: string;
}) {
  return (
    <div className="bg-cc-panel border border-cc-border rounded-lg p-4">
      <div className="text-xs text-cc-text-muted mb-1">{label}</div>
      <div className="text-2xl font-bold">{value}</div>
      {sub && <div className="text-xs text-cc-text-dim mt-1">{sub}</div>}
    </div>
  );
}

function RoleBadge({ role }: { role: string }) {
  const colors: Record<string, string> = {
    "직접 편집": "bg-blue-500/20 text-blue-400",
    "자동 축적": "bg-green-500/20 text-green-400",
    "aib 관리": "bg-purple-500/20 text-purple-400",
  };
  return (
    <span
      className={`text-[10px] px-1.5 py-0.5 rounded font-medium whitespace-nowrap ${colors[role] ?? "bg-gray-500/20 text-gray-400"}`}
    >
      {role}
    </span>
  );
}

export function BarrackOverview() {
  const { selectedBarrack, cliVersion, fetchBarracks } = useAppStore();
  const [syncing, setSyncing] = useState(false);
  const [syncOutput, setSyncOutput] = useState<string | null>(null);
  const [launching, setLaunching] = useState(false);
  const [skipPermissions, setSkipPermissions] = useState(false);

  if (!selectedBarrack) return null;

  const b = selectedBarrack;
  const isOutdated = cliVersion && b.aib_version !== cliVersion;
  const totalRules =
    b.rules_count.must_always + b.rules_count.must_never + b.rules_count.learned;

  const handleSync = async () => {
    setSyncing(true);
    setSyncOutput(null);
    try {
      const output = await invoke<string>("sync_barrack", {
        barrackPath: b.path,
        dryRun: false,
      });
      setSyncOutput(output);
      await fetchBarracks();
    } catch (e) {
      setSyncOutput(`Error: ${e}`);
    } finally {
      setSyncing(false);
    }
  };

  const handleLaunch = async (client: string) => {
    setLaunching(true);
    try {
      await invoke("launch_session", {
        barrackPath: b.path,
        client,
        skipPermissions,
      });
    } catch (e) {
      alert(`세션 실행 실패: ${e}`);
    } finally {
      setLaunching(false);
    }
  };

  return (
    <div className="p-6 max-w-4xl">
      {/* Header */}
      <div className="mb-6">
        <div className="flex items-center gap-3 mb-2">
          <h2 className="text-xl font-bold">{b.soul_summary.name || b.name}</h2>
          <span
            className={`text-xs px-2 py-0.5 rounded font-medium ${
              isOutdated
                ? "bg-cc-warning/20 text-cc-warning"
                : "bg-cc-success/20 text-cc-success"
            }`}
          >
            v{b.aib_version}
          </span>
          {isOutdated && (
            <button
              onClick={handleSync}
              disabled={syncing}
              className="text-xs px-3 py-1 bg-cc-accent hover:bg-cc-accent-dim text-white rounded transition-colors disabled:opacity-50"
            >
              {syncing ? "Syncing..." : `Sync to v${cliVersion}`}
            </button>
          )}
        </div>
        {b.description && (
          <p className="text-sm text-cc-text-dim">{b.description}</p>
        )}
      </div>

      {/* Expertise tags */}
      {b.soul_summary.expertise.length > 0 && (
        <div className="mb-6">
          <h3 className="text-xs font-medium text-cc-text-muted mb-2 uppercase tracking-wider">
            Expertise
          </h3>
          <div className="flex flex-wrap gap-2">
            {b.soul_summary.expertise.map((e) => (
              <span
                key={e}
                className="text-xs px-2.5 py-1 bg-cc-accent/10 text-cc-accent border border-cc-accent/20 rounded-full"
              >
                {e}
              </span>
            ))}
          </div>
        </div>
      )}

      {/* Stats grid */}
      <div className="grid grid-cols-4 gap-3 mb-6">
        <StatCard
          label="Agents"
          value={b.session_count}
          sub={b.active_sessions > 0 ? `${b.active_sessions} active` : undefined}
        />
        <StatCard label="Wiki Topics" value={b.wiki_topic_count} />
        <StatCard
          label="Rules"
          value={totalRules}
          sub={`A:${b.rules_count.must_always} N:${b.rules_count.must_never} L:${b.rules_count.learned}`}
        />
        <StatCard label="Version" value={`v${b.aib_version}`} />
      </div>

      {/* Config files reference */}
      <div className="mb-6">
        <h3 className="text-xs font-medium text-cc-text-muted mb-2 uppercase tracking-wider">
          Config Files
        </h3>
        <div className="bg-cc-panel border border-cc-border rounded-lg p-3">
          <div className="grid grid-cols-2 gap-2 text-xs">
            {[
              { file: "GROWTH.md", role: "직접 편집", desc: "성장 트리거와 지식 기록 규칙" },
              { file: "RULES.md", role: "자동 축적", desc: "세션에서 학습한 행동 규칙" },
              { file: "SOUL.md", role: "직접 편집", desc: "에이전트 이름, 전문성, 성격" },
              { file: "agent.yaml", role: "aib 관리", desc: "메타데이터, 모델, 버전" },
            ].map((f) => (
              <div key={f.file} className="flex items-center gap-2 py-1">
                <span className="text-cc-text-dim w-24">{f.file}</span>
                <RoleBadge role={f.role} />
                <span className="text-cc-text-muted">{f.desc}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Quick actions */}
      <div className="mb-6">
        <h3 className="text-xs font-medium text-cc-text-muted mb-2 uppercase tracking-wider">
          New Agent
        </h3>
        <div className="flex items-center gap-3">
          <div className="flex gap-2">
            {["claude", "gemini", "codex"].map((client) => (
              <button
                key={client}
                onClick={() => handleLaunch(client)}
                disabled={launching}
                className="px-4 py-2 text-sm bg-cc-panel border border-cc-border rounded-lg hover:border-cc-accent/40 hover:bg-cc-accent/10 transition-colors disabled:opacity-50"
              >
                {client.charAt(0).toUpperCase() + client.slice(1)}
              </button>
            ))}
          </div>
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

      {/* Sync output */}
      {syncOutput && (
        <div className="bg-cc-panel border border-cc-border rounded-lg p-4">
          <h3 className="text-xs font-medium text-cc-text-muted mb-2">
            Sync Output
          </h3>
          <pre className="text-xs text-cc-text-dim whitespace-pre-wrap font-mono">
            {syncOutput}
          </pre>
        </div>
      )}
    </div>
  );
}
