import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { OwnershipBanner } from "./OwnershipBanner";

interface SoulData {
  name: string;
  expertise: string[];
  personality: string[];
  core_values: string[];
  constraints: string[];
}

function parseSoul(content: string): SoulData {
  const data: SoulData = {
    name: "",
    expertise: [],
    personality: [],
    core_values: [],
    constraints: [],
  };
  let section = "";

  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith("## Name")) { section = "name"; continue; }
    if (trimmed.startsWith("## Expertise")) { section = "expertise"; continue; }
    if (trimmed.startsWith("## Personality")) { section = "personality"; continue; }
    if (trimmed.startsWith("## Core Values")) { section = "core_values"; continue; }
    if (trimmed.startsWith("## Constraints")) { section = "constraints"; continue; }
    if (trimmed.startsWith("## ") || trimmed.startsWith("# ")) { section = ""; continue; }
    if (trimmed.startsWith("<!--")) continue;

    if (section === "name" && trimmed && !data.name) {
      data.name = trimmed;
    } else if (section && trimmed.startsWith("- ")) {
      const item = trimmed.slice(2);
      if (section === "expertise") data.expertise.push(item);
      if (section === "personality") data.personality.push(item);
      if (section === "core_values") data.core_values.push(item);
      if (section === "constraints") data.constraints.push(item);
    }
  }
  return data;
}

function buildSoul(data: SoulData): string {
  let md = "<!-- AIB:SOUL:v1 — 이 구조를 유지하세요. 내용은 자유롭게 수정 가능합니다. -->\n";
  md += "# Agent Identity\n\n";
  md += `## Name\n${data.name}\n\n`;
  md += "## Expertise\n";
  for (const e of data.expertise) md += `- ${e}\n`;
  md += "\n## Personality\n";
  for (const p of data.personality) md += `- ${p}\n`;
  md += "\n## Core Values\n";
  for (const v of data.core_values) md += `- ${v}\n`;
  md += "\n## Constraints\n";
  for (const c of data.constraints) md += `- ${c}\n`;
  md += "\n<!-- AIB:SOUL:END -->\n";
  return md;
}

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
  const [data, setData] = useState<SoulData | null>(null);
  const [hasChanges, setHasChanges] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!selectedBarrack) return;
    try {
      const content = await invoke<string>("read_file", {
        filePath: `${selectedBarrack.path}/SOUL.md`,
      });
      setData(parseSoul(content));
      setHasChanges(false);
    } catch (e) {
      console.error("Failed to load SOUL.md:", e);
    }
  }, [selectedBarrack]);

  useEffect(() => { load(); }, [load]);

  const update = (partial: Partial<SoulData>) => {
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
        filePath: `${selectedBarrack.path}/SOUL.md`,
        content: buildSoul(data),
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
