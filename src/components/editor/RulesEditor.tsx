import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import type { RulesData } from "../../types";

function RuleSection({
  title,
  color,
  rules,
  onDelete,
  onAdd,
}: {
  title: string;
  color: string;
  rules: string[];
  onDelete: (index: number) => void;
  onAdd: (rule: string) => void;
}) {
  const [newRule, setNewRule] = useState("");

  const handleAdd = () => {
    if (newRule.trim()) {
      onAdd(newRule.trim());
      setNewRule("");
    }
  };

  return (
    <div className="mb-6">
      <h3 className={`text-[13px] font-semibold mb-2 ${color}`}>
        {title}
        <span className="text-cc-text-muted font-normal ml-2">({rules.length})</span>
      </h3>
      <div className="space-y-1">
        {rules.map((rule, i) => (
          <div
            key={i}
            className="flex items-start gap-2 group px-3 py-1.5 rounded-md hover:bg-cc-card-hover transition-colors"
          >
            <span className="text-[12px] text-cc-text-dim flex-1 leading-relaxed">
              {rule}
            </span>
            <button
              onClick={() => onDelete(i)}
              className="text-[11px] text-cc-text-muted opacity-0 group-hover:opacity-100 hover:text-cc-danger transition-all shrink-0"
            >
              delete
            </button>
          </div>
        ))}
        {rules.length === 0 && (
          <p className="text-[12px] text-cc-text-muted px-3 py-1">
            (no rules)
          </p>
        )}
      </div>
      <div className="flex items-center gap-2 mt-2">
        <input
          type="text"
          value={newRule}
          onChange={(e) => setNewRule(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && handleAdd()}
          placeholder="Add rule..."
          className="flex-1 text-[12px] px-2.5 py-1.5 bg-cc-panel border border-cc-border rounded-md text-cc-text placeholder:text-cc-text-muted focus:outline-none focus:border-cc-accent/50"
        />
        <button
          onClick={handleAdd}
          disabled={!newRule.trim()}
          className="text-[12px] px-3 py-1.5 bg-cc-accent text-white rounded-md hover:bg-cc-accent-dim transition-colors disabled:opacity-40"
        >
          Add
        </button>
      </div>
    </div>
  );
}

export function RulesEditor() {
  const { selectedBarrack, fetchBarracks } = useAppStore();
  const [rules, setRules] = useState<RulesData | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);
  const [hasChanges, setHasChanges] = useState(false);

  const loadRules = useCallback(async () => {
    if (!selectedBarrack) return;
    try {
      const data = await invoke<RulesData>("get_rules", {
        barrackPath: selectedBarrack.path,
      });
      setRules(data);
      setHasChanges(false);
    } catch (e) {
      console.error("Failed to load rules:", e);
    }
  }, [selectedBarrack]);

  useEffect(() => {
    loadRules();
  }, [loadRules]);

  const updateRules = (updated: RulesData) => {
    setRules(updated);
    setHasChanges(true);
  };

  const handleSave = async () => {
    if (!selectedBarrack || !rules) return;
    setSaving(true);
    setSaveMsg(null);
    try {
      await invoke("save_rules", {
        barrackPath: selectedBarrack.path,
        rules,
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

  if (!rules) return null;

  return (
    <div className="flex-1 flex flex-col">
      <div className="flex items-center justify-between px-4 py-2 border-b border-cc-border">
        <div className="flex items-center gap-2">
          <span className="text-[13px] font-medium">RULES.md</span>
          <span className="text-[10px] px-1.5 py-0.5 rounded font-medium bg-green-500/20 text-green-400">
            자동 축적
          </span>
          {hasChanges && (
            <span className="text-[11px] text-cc-warning">수정됨</span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {saveMsg && (
            <span className="text-[11px] text-cc-success">{saveMsg}</span>
          )}
          <button
            onClick={handleSave}
            disabled={!hasChanges || saving}
            className="text-[12px] px-3 py-1 bg-cc-accent text-white rounded-md hover:bg-cc-accent-dim transition-colors disabled:opacity-30"
          >
            {saving ? "저장 중..." : "저장"}
          </button>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto p-5">
        <RuleSection
          title="Must Always"
          color="text-cc-success"
          rules={rules.must_always}
          onDelete={(i) => {
            const next = { ...rules, must_always: rules.must_always.filter((_, j) => j !== i) };
            updateRules(next);
          }}
          onAdd={(rule) => {
            updateRules({ ...rules, must_always: [...rules.must_always, rule] });
          }}
        />
        <RuleSection
          title="Must Never"
          color="text-cc-danger"
          rules={rules.must_never}
          onDelete={(i) => {
            const next = { ...rules, must_never: rules.must_never.filter((_, j) => j !== i) };
            updateRules(next);
          }}
          onAdd={(rule) => {
            updateRules({ ...rules, must_never: [...rules.must_never, rule] });
          }}
        />
        <RuleSection
          title="Learned"
          color="text-cc-accent"
          rules={rules.learned}
          onDelete={(i) => {
            const next = { ...rules, learned: rules.learned.filter((_, j) => j !== i) };
            updateRules(next);
          }}
          onAdd={(rule) => {
            updateRules({ ...rules, learned: [...rules.learned, rule] });
          }}
        />
      </div>
    </div>
  );
}
