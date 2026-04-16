import { useAppStore } from "../../stores/appStore";
import { useTerminalStore } from "../../stores/terminalStore";

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
  const { selectedBarrack, cliVersion, openConfigFile, setActiveTab } = useAppStore();

  if (!selectedBarrack) return null;

  const b = selectedBarrack;
  const isOutdated = cliVersion && b.aib_version !== cliVersion;
  const totalRules =
    b.rules_count.must_always + b.rules_count.must_never + b.rules_count.learned;

  const handleSync = () => {
    const aib = "/opt/homebrew/bin/aib";
    useTerminalStore.getState().addSession({
      id: crypto.randomUUID(),
      title: `Sync - ${b.name}`,
      barrackPath: b.path,
      cwd: b.path,
      initialCommand: `${aib} sync --dry-run '${b.path}' && echo '\\n--- Press enter to apply ---' && read && ${aib} sync '${b.path}'`,
      source: "terminal",
    });
    setActiveTab("sessions");
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
              className="text-xs px-3 py-1 bg-cc-accent hover:bg-cc-accent-dim text-white rounded transition-colors"
            >
              Sync to v{cliVersion}
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
              <button
                key={f.file}
                onClick={() => openConfigFile(f.file)}
                className="flex items-center gap-2 py-1 text-left hover:bg-cc-card-hover rounded px-1 -mx-1 transition-colors"
              >
                <span className="text-cc-text-dim w-24 hover:text-cc-accent transition-colors">{f.file}</span>
                <RoleBadge role={f.role} />
                <span className="text-cc-text-muted">{f.desc}</span>
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Quick actions — redirect to Agents tab */}
      <div className="mb-6">
        <h3 className="text-xs font-medium text-cc-text-muted mb-2 uppercase tracking-wider">
          Agents
        </h3>
        <button
          onClick={() => setActiveTab("sessions")}
          className="px-4 py-2 text-sm bg-cc-panel border border-cc-border rounded-lg hover:border-cc-accent/40 hover:bg-cc-accent/10 transition-colors"
        >
          Launch Agent / Open Terminal →
        </button>
      </div>

    </div>
  );
}
