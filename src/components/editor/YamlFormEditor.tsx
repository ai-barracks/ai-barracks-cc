import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { OwnershipBanner } from "./OwnershipBanner";

interface AgentConfig {
  name: string;
  version: string;
  description: string;
  primary_model: string;
  fallback_models: string[];
  aib_version: string;
  raw: string;
}

function parseYaml(content: string): AgentConfig {
  const config: AgentConfig = {
    name: "",
    version: "",
    description: "",
    primary_model: "",
    fallback_models: [],
    aib_version: "",
    raw: content,
  };

  let inFallback = false;
  for (const line of content.split("\n")) {
    if (line.startsWith("name:")) {
      config.name = line.replace("name:", "").trim().replace(/"/g, "");
    } else if (line.startsWith("version:")) {
      config.version = line.replace("version:", "").trim().replace(/"/g, "");
    } else if (line.startsWith("description:")) {
      config.description = line.replace("description:", "").trim().replace(/"/g, "");
    } else if (line.startsWith("aib_version:")) {
      config.aib_version = line.replace("aib_version:", "").trim();
    } else if (line.match(/^\s+primary:/)) {
      config.primary_model = line.replace(/.*primary:/, "").trim();
      inFallback = false;
    } else if (line.match(/^\s+fallback:/)) {
      inFallback = true;
    } else if (inFallback && line.match(/^\s+- /)) {
      config.fallback_models.push(line.replace(/^\s+- /, "").trim());
    } else if (inFallback && !line.match(/^\s/)) {
      inFallback = false;
    }
  }
  return config;
}

function buildYaml(config: AgentConfig): string {
  let yaml = `name: ${config.name}\n`;
  yaml += `version: ${config.version}\n`;
  yaml += `description: "${config.description}"\n`;
  yaml += `\nmodels:\n`;
  yaml += `  primary: ${config.primary_model}\n`;
  if (config.fallback_models.length > 0) {
    yaml += `  fallback:\n`;
    for (const m of config.fallback_models) {
      yaml += `    - ${m}\n`;
    }
  }
  yaml += `\nmemory:\n  sessions: sessions/\n  wiki: wiki/\n`;
  yaml += `\nhooks:\n  session_start: "aib hook start {client}"\n  session_end: "aib hook end {client}"\n`;
  yaml += `\nskills:\n  - council\n`;
  yaml += `\ncompliance:\n  session_retention: permanent\n  wiki_retention: permanent\n`;
  yaml += `\naib_version: ${config.aib_version}\n`;
  return yaml;
}

function Field({
  label,
  value,
  onChange,
  disabled,
  mono,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  disabled?: boolean;
  mono?: boolean;
}) {
  return (
    <div className="flex items-center gap-3 mb-3">
      <label className="text-[12px] text-cc-text-muted w-28 shrink-0 text-right">
        {label}
      </label>
      <input
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        disabled={disabled}
        className={`flex-1 text-[13px] px-2.5 py-1.5 bg-cc-panel border border-cc-border rounded-md text-cc-text focus:outline-none focus:border-cc-accent/50 disabled:opacity-50 ${mono ? "font-mono text-[12px]" : ""}`}
      />
    </div>
  );
}

export function YamlFormEditor() {
  const { selectedBarrack, fetchBarracks } = useAppStore();
  const [config, setConfig] = useState<AgentConfig | null>(null);
  const [hasChanges, setHasChanges] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);

  const loadConfig = useCallback(async () => {
    if (!selectedBarrack) return;
    try {
      const content = await invoke<string>("read_file", {
        filePath: `${selectedBarrack.path}/agent.yaml`,
      });
      setConfig(parseYaml(content));
      setHasChanges(false);
    } catch (e) {
      console.error("Failed to load agent.yaml:", e);
    }
  }, [selectedBarrack]);

  useEffect(() => {
    loadConfig();
  }, [loadConfig]);

  const update = (partial: Partial<AgentConfig>) => {
    if (!config) return;
    setConfig({ ...config, ...partial });
    setHasChanges(true);
  };

  const handleSave = async () => {
    if (!selectedBarrack || !config) return;
    setSaving(true);
    setSaveMsg(null);
    try {
      await invoke("write_file", {
        filePath: `${selectedBarrack.path}/agent.yaml`,
        content: buildYaml(config),
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

  if (!config) return null;

  return (
    <div className="flex-1 flex flex-col">
      <OwnershipBanner ownership="aib 관리" />
      <div className="flex items-center justify-between px-4 py-2 border-b border-cc-border">
        <div className="flex items-center gap-2">
          <span className="text-[13px] font-medium">agent.yaml</span>
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

      <div className="flex-1 overflow-y-auto p-5 max-w-xl">
        <h3 className="text-[11px] text-cc-text-muted uppercase tracking-wider mb-3 font-medium">
          Basic Info
        </h3>
        <Field label="Name" value={config.name} onChange={(v) => update({ name: v })} />
        <Field label="Version" value={config.version} onChange={(v) => update({ version: v })} mono />
        <Field
          label="Description"
          value={config.description}
          onChange={(v) => update({ description: v })}
        />

        <h3 className="text-[11px] text-cc-text-muted uppercase tracking-wider mb-3 mt-6 font-medium">
          Models
        </h3>
        <Field
          label="Primary"
          value={config.primary_model}
          onChange={(v) => update({ primary_model: v })}
          mono
        />
        {config.fallback_models.map((m, i) => (
          <div key={i} className="flex items-center gap-3 mb-3">
            <label className="text-[12px] text-cc-text-muted w-28 shrink-0 text-right">
              Fallback {i + 1}
            </label>
            <input
              type="text"
              value={m}
              onChange={(e) => {
                const next = [...config.fallback_models];
                next[i] = e.target.value;
                update({ fallback_models: next });
              }}
              className="flex-1 text-[12px] font-mono px-2.5 py-1.5 bg-cc-panel border border-cc-border rounded-md text-cc-text focus:outline-none focus:border-cc-accent/50"
            />
            <button
              onClick={() => {
                update({
                  fallback_models: config.fallback_models.filter((_, j) => j !== i),
                });
              }}
              className="text-[11px] text-cc-text-muted hover:text-cc-danger transition-colors"
            >
              delete
            </button>
          </div>
        ))}
        <div className="flex items-center gap-3">
          <span className="w-28" />
          <button
            onClick={() =>
              update({ fallback_models: [...config.fallback_models, ""] })
            }
            className="text-[12px] text-cc-accent hover:text-cc-accent-dim transition-colors"
          >
            + Add fallback model
          </button>
        </div>

        <h3 className="text-[11px] text-cc-text-muted uppercase tracking-wider mb-3 mt-6 font-medium">
          System
        </h3>
        <Field
          label="aib_version"
          value={config.aib_version}
          onChange={() => {}}
          disabled
          mono
        />
      </div>
    </div>
  );
}
