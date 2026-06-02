import { useEffect, useRef, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { OwnershipBanner } from "./OwnershipBanner";
import {
  parseSoulDocument,
  patchSoulDocument,
  type SoulData,
} from "./soulDocument";

function ListField({
  label,
  items,
  placeholder,
  onAdd,
  onRemove,
}: {
  label: string;
  items: string[];
  placeholder: string;
  onAdd: (item: string) => void;
  onRemove: (index: number) => void;
}) {
  const [input, setInput] = useState("");

  return (
    <div className="mb-5">
      <h3 className="text-[12px] font-medium text-cc-text-dim mb-2">{label}</h3>
      <div className="space-y-1 mb-2">
        {items.map((item, i) => (
          <div key={i} className="flex items-center gap-2 group">
            <span className="text-[13px] text-cc-text flex-1 px-2.5 py-1.5 bg-cc-panel border border-cc-border rounded-md">
              {item}
            </span>
            <button
              onClick={() => onRemove(i)}
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
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && input.trim()) {
              onAdd(input.trim());
              setInput("");
            }
          }}
          placeholder={placeholder}
          className="flex-1 text-[13px] px-2.5 py-1.5 bg-cc-panel border border-cc-border rounded-md text-cc-text placeholder:text-cc-text-muted focus:outline-none focus:border-cc-accent/50"
        />
        <button
          onClick={() => {
            if (input.trim()) { onAdd(input.trim()); setInput(""); }
          }}
          disabled={!input.trim()}
          className="text-[12px] px-3 py-1.5 bg-cc-accent text-white rounded-md hover:bg-cc-accent-dim transition-colors disabled:opacity-40"
        >
          Add
        </button>
      </div>
    </div>
  );
}

export function SoulFormEditor() {
  const { selectedBarrack, fetchBarracks } = useAppStore();
  const barrackPath = selectedBarrack?.path;
  const [raw, setRaw] = useState<string | null>(null);
  const [data, setData] = useState<SoulData | null>(null);
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
        filename: "SOUL.md",
      });
      const doc = parseSoulDocument(content);
      setRaw(doc.raw);
      setData(doc.data);
      setHasChanges(false);
    } catch (e) {
      console.error("Failed to load SOUL.md:", e);
    }
  }, [barrackPath]);

  useEffect(() => { load(); }, [load]);

  const update = (partial: Partial<SoulData>) => {
    if (!data) return;
    setData({ ...data, ...partial });
    setHasChanges(true);
  };

  const handleSave = async () => {
    if (!barrackPath || !data || raw === null) return;
    setSaving(true);
    setSaveMsg(null);
    const patched = patchSoulDocument(raw, data);
    if (!patched.ok) {
      setSaveMsg(`저장 실패: ${patched.failure.field} ${patched.failure.reason}`);
      setSaving(false);
      return;
    }
    try {
      await invoke("write_barrack_file", {
        barrackPath,
        filename: "SOUL.md",
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
          <span className="text-[13px] font-medium">SOUL.md</span>
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

      <div className="flex-1 overflow-y-auto p-5 max-w-xl">
        <div className="mb-5">
          <h3 className="text-[12px] font-medium text-cc-text-dim mb-2">Name</h3>
          <input
            type="text"
            value={data.name}
            onChange={(e) => update({ name: e.target.value })}
            className="w-full text-[13px] px-2.5 py-1.5 bg-cc-panel border border-cc-border rounded-md text-cc-text focus:outline-none focus:border-cc-accent/50"
          />
        </div>

        <ListField
          label="Expertise"
          items={data.expertise}
          placeholder="전문 분야 추가..."
          onAdd={(item) => update({ expertise: [...data.expertise, item] })}
          onRemove={(i) => update({ expertise: data.expertise.filter((_, j) => j !== i) })}
        />
        <ListField
          label="Personality"
          items={data.personality}
          placeholder="성격/톤 추가..."
          onAdd={(item) => update({ personality: [...data.personality, item] })}
          onRemove={(i) => update({ personality: data.personality.filter((_, j) => j !== i) })}
        />
        <ListField
          label="Core Values"
          items={data.core_values}
          placeholder="핵심 가치 추가..."
          onAdd={(item) => update({ core_values: [...data.core_values, item] })}
          onRemove={(i) => update({ core_values: data.core_values.filter((_, j) => j !== i) })}
        />
        <ListField
          label="Constraints"
          items={data.constraints}
          placeholder="제약 조건 추가..."
          onAdd={(item) => update({ constraints: [...data.constraints, item] })}
          onRemove={(i) => update({ constraints: data.constraints.filter((_, j) => j !== i) })}
        />
      </div>
    </div>
  );
}
