import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { OwnershipBanner } from "./OwnershipBanner";

interface DecisionRow {
  event: string;
  location: string;
  example: string;
}

interface GrowthData {
  decision_table: DecisionRow[];
  not_growth_worthy: string[];
}

function parseGrowth(content: string): GrowthData {
  const data: GrowthData = { decision_table: [], not_growth_worthy: [] };
  let inTable = false;
  let inNotGrowth = false;

  for (const line of content.split("\n")) {
    const trimmed = line.trim();

    // Decision Table
    if (trimmed.includes("세션 중 이벤트") && trimmed.startsWith("|")) {
      inTable = true;
      inNotGrowth = false;
      continue;
    }
    if (inTable && trimmed.startsWith("|") && trimmed.includes("---")) continue;
    if (inTable && trimmed.startsWith("|")) {
      const cols = trimmed.split("|").filter(Boolean);
      if (cols.length >= 3) {
        data.decision_table.push({
          event: cols[0].trim(),
          location: cols[1].trim(),
          example: cols[2].trim(),
        });
      }
      continue;
    }
    if (inTable && !trimmed.startsWith("|") && trimmed) {
      inTable = false;
    }

    // NOT growth-worthy
    if (trimmed.startsWith("**NOT growth-worthy**") || trimmed.includes("기록하지 않을 것")) {
      inNotGrowth = true;
      inTable = false;
      continue;
    }
    if (inNotGrowth && trimmed.startsWith("- ")) {
      data.not_growth_worthy.push(trimmed.slice(2));
      continue;
    }
    if (inNotGrowth && trimmed.startsWith("##")) {
      inNotGrowth = false;
    }
  }
  return data;
}

function buildGrowth(data: GrowthData): string {
  let md = "<!-- AIB:OWNERSHIP — [USER-OWNED] 사용자가 배럭에 맞게 커스터마이징하는 파일. 에이전트는 읽기만 합니다. -->\n";
  md += "# Growth Protocol\n\n";
  md += "> 에이전트가 세션 중 wiki/, RULES.md를 **자발적으로 성장시키기 위한 결정 규칙**.\n";
  md += "> 이 파일은 배럭별로 자유롭게 커스터마이징 가능하다 (sync 시 덮어쓰지 않음).\n\n";
  md += "## Decision Table — 발견 즉시 기록 (CRITICAL)\n\n";
  md += "세션 **종료 시**가 아니라, **발견하는 즉시** 아래 표에 따라 기록한다.\n\n";
  md += "| 세션 중 이벤트 | 기록 위치 | 예시 |\n";
  md += "|---------------|-----------|------|\n";
  for (const row of data.decision_table) {
    md += `| ${row.event} | ${row.location} | ${row.example} |\n`;
  }
  md += "\n**NOT growth-worthy** — 기록하지 않을 것:\n";
  for (const item of data.not_growth_worthy) {
    md += `- ${item}\n`;
  }
  md += "\n## End-of-Session Audit\n\n";
  md += "세션 종료 전, 위 Decision Table을 기준으로 누락을 점검한다.\n";
  md += "종료 시점은 **저장 시점이 아니라 감사(audit) 시점**이다.\n\n";
  md += "1. `## Decisions` 검토 → wiki/RULES에 반영할 것이 있는가?\n";
  md += "2. `## Log` 검토 → 재사용 가능한 지식이 있는가?\n";
  md += "3. 오류/수정 검토 → 학습한 규칙이 있는가?\n";
  return md;
}

export function GrowthFormEditor() {
  const { selectedBarrack, fetchBarracks } = useAppStore();
  const [data, setData] = useState<GrowthData | null>(null);
  const [hasChanges, setHasChanges] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!selectedBarrack) return;
    try {
      const content = await invoke<string>("read_file", {
        filePath: `${selectedBarrack.path}/GROWTH.md`,
      });
      setData(parseGrowth(content));
      setHasChanges(false);
    } catch (e) {
      console.error("Failed to load GROWTH.md:", e);
    }
  }, [selectedBarrack]);

  useEffect(() => { load(); }, [load]);

  const update = (partial: Partial<GrowthData>) => {
    if (!data) return;
    setData({ ...data, ...partial });
    setHasChanges(true);
  };

  const handleSave = async () => {
    if (!selectedBarrack || !data) return;
    setSaving(true);
    setSaveMsg(null);
    try {
      await invoke("write_file", {
        filePath: `${selectedBarrack.path}/GROWTH.md`,
        content: buildGrowth(data),
      });
      setHasChanges(false);
      setSaveMsg("저장 완료");
      await fetchBarracks();
      setTimeout(() => setSaveMsg(null), 2000);
    } catch (e) {
      setSaveMsg(`저장 실패: ${e}`);
    } finally {
      setSaving(false);
    }
  };

  if (!data) return null;

  return (
    <div className="flex-1 flex flex-col">
      <OwnershipBanner ownership="직접 편집" />
      <div className="flex items-center justify-between px-4 py-2 border-b border-cc-border">
        <div className="flex items-center gap-2">
          <span className="text-[13px] font-medium">GROWTH.md</span>
          {hasChanges && <span className="text-[11px] text-cc-warning">수정됨</span>}
        </div>
        <div className="flex items-center gap-2">
          {saveMsg && <span className="text-[11px] text-cc-success">{saveMsg}</span>}
          <button
            onClick={handleSave}
            disabled={!hasChanges || saving}
            className="text-[12px] px-3 py-1 bg-cc-accent text-white rounded-md hover:bg-cc-accent-dim transition-colors disabled:opacity-30"
          >
            {saving ? "저장 중..." : "저장"}
          </button>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto p-5 max-w-3xl">
        {/* Decision Table */}
        <h3 className="text-[13px] font-semibold mb-3">Decision Table</h3>
        <p className="text-[12px] text-cc-text-muted mb-3">
          에이전트가 세션 중 지식을 발견하면 어디에 기록할지 결정하는 규칙입니다.
        </p>

        <div className="border border-cc-border rounded-lg overflow-hidden shadow-cc mb-4">
          <table className="w-full text-[13px]">
            <thead>
              <tr className="bg-cc-panel/50 text-[11px] text-cc-text-muted uppercase tracking-wider">
                <th className="px-3 py-2 text-left">이벤트</th>
                <th className="px-3 py-2 text-left w-40">기록 위치</th>
                <th className="px-3 py-2 text-left w-44">예시</th>
                <th className="px-3 py-2 w-12"></th>
              </tr>
            </thead>
            <tbody>
              {data.decision_table.map((row, i) => (
                <tr key={i} className="border-t border-cc-border group">
                  <td className="px-3 py-1.5">
                    <input
                      type="text"
                      value={row.event}
                      onChange={(e) => {
                        const next = [...data.decision_table];
                        next[i] = { ...next[i], event: e.target.value };
                        update({ decision_table: next });
                      }}
                      className="w-full bg-transparent text-cc-text focus:outline-none"
                    />
                  </td>
                  <td className="px-3 py-1.5">
                    <input
                      type="text"
                      value={row.location}
                      onChange={(e) => {
                        const next = [...data.decision_table];
                        next[i] = { ...next[i], location: e.target.value };
                        update({ decision_table: next });
                      }}
                      className="w-full bg-transparent text-cc-accent font-mono text-[12px] focus:outline-none"
                    />
                  </td>
                  <td className="px-3 py-1.5">
                    <input
                      type="text"
                      value={row.example}
                      onChange={(e) => {
                        const next = [...data.decision_table];
                        next[i] = { ...next[i], example: e.target.value };
                        update({ decision_table: next });
                      }}
                      className="w-full bg-transparent text-cc-text-dim focus:outline-none"
                    />
                  </td>
                  <td className="px-3 py-1.5 text-center">
                    <button
                      onClick={() => {
                        update({
                          decision_table: data.decision_table.filter((_, j) => j !== i),
                        });
                      }}
                      className="text-[11px] text-cc-text-muted opacity-0 group-hover:opacity-100 hover:text-cc-danger transition-all"
                    >
                      del
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <button
          onClick={() => {
            update({
              decision_table: [
                ...data.decision_table,
                { event: "", location: "", example: "" },
              ],
            });
          }}
          className="text-[12px] text-cc-accent hover:text-cc-accent-dim transition-colors mb-8"
        >
          + Add row
        </button>

        {/* NOT growth-worthy */}
        <h3 className="text-[13px] font-semibold mb-2">NOT Growth-Worthy</h3>
        <p className="text-[12px] text-cc-text-muted mb-3">
          이런 것들은 기록하지 않습니다 (에이전트에게 불필요한 기록을 방지).
        </p>
        <div className="space-y-1 mb-2">
          {data.not_growth_worthy.map((item, i) => (
            <div key={i} className="flex items-center gap-2 group">
              <span className="text-[13px] text-cc-text-dim flex-1 px-2.5 py-1.5 bg-cc-panel border border-cc-border rounded-md">
                {item}
              </span>
              <button
                onClick={() => {
                  update({
                    not_growth_worthy: data.not_growth_worthy.filter((_, j) => j !== i),
                  });
                }}
                className="text-[11px] text-cc-text-muted opacity-0 group-hover:opacity-100 hover:text-cc-danger transition-all"
              >
                delete
              </button>
            </div>
          ))}
        </div>
        <div className="flex items-center gap-2">
          <input
            type="text"
            placeholder="제외 항목 추가..."
            className="flex-1 text-[13px] px-2.5 py-1.5 bg-cc-panel border border-cc-border rounded-md text-cc-text placeholder:text-cc-text-muted focus:outline-none focus:border-cc-accent/50"
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.target as HTMLInputElement).value.trim()) {
                update({
                  not_growth_worthy: [
                    ...data.not_growth_worthy,
                    (e.target as HTMLInputElement).value.trim(),
                  ],
                });
                (e.target as HTMLInputElement).value = "";
              }
            }}
          />
        </div>
      </div>
    </div>
  );
}
