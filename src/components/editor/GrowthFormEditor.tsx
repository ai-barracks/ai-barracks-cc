import { useEffect, useRef, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { OwnershipBanner } from "./OwnershipBanner";

import {
  parseGrowthDocument,
  patchGrowthDocument,
  type GrowthData,
} from "./growthDocument";
export function GrowthFormEditor() {
  const { selectedBarrack, fetchBarracks } = useAppStore();
  const barrackPath = selectedBarrack?.path;
  const [raw, setRaw] = useState<string | null>(null);
  const [data, setData] = useState<GrowthData | null>(null);
  const [hasChanges, setHasChanges] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);
  const hasChangesRef = useRef(false);
  useEffect(() => {
    hasChangesRef.current = hasChanges;
  }, [hasChanges]);

  const load = useCallback(async () => {
    if (!barrackPath) return;
    if (hasChangesRef.current) return;
    try {
      const content = await invoke<string>("read_barrack_file", {
        barrackPath,
        filename: "GROWTH.md",
      });
      const doc = parseGrowthDocument(content);
      setRaw(doc.raw);
      setData(doc.data);
      setHasChanges(false);
    } catch (e) {
      console.error("Failed to load GROWTH.md:", e);
    }
  }, [barrackPath]);

  useEffect(() => { load(); }, [load]);

  const update = (partial: Partial<GrowthData>) => {
    if (!data) return;
    setData({ ...data, ...partial });
    setHasChanges(true);
  };

  const handleSave = async () => {
    if (!barrackPath || !data || raw === null) return;
    setSaving(true);
    setSaveMsg(null);
    const patched = patchGrowthDocument(raw, data);
    if (!patched.ok) {
      setSaveMsg(`저장 실패: ${patched.failure.field} ${patched.failure.reason}`);
      setSaving(false);
      return;
    }
    try {
      await invoke("write_barrack_file", {
        barrackPath,
        filename: "GROWTH.md",
        content: patched.raw,
      });
      setRaw(patched.raw);
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
