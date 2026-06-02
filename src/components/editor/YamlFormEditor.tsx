import { useEffect, useRef, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { OwnershipBanner } from "./OwnershipBanner";

import {
  parseAgentYamlDocument,
  patchAgentYamlDocument,
  type AgentConfig,
} from "./yamlDocument";

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
  const barrackPath = selectedBarrack?.path;
  const [config, setConfig] = useState<AgentConfig | null>(null);
  const [rawConfig, setRawConfig] = useState("");
  const [hasChanges, setHasChanges] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);
  const hasChangesRef = useRef(false);
  useEffect(() => {
    hasChangesRef.current = hasChanges;
  }, [hasChanges]);

  const loadConfig = useCallback(async () => {
    if (!barrackPath) return;
    if (hasChangesRef.current) return;
    try {
      const content = await invoke<string>("read_barrack_file", {
        barrackPath,
        filename: "agent.yaml",
      });
      const doc = parseAgentYamlDocument(content);
      setConfig(doc.data);
      setRawConfig(doc.raw);
      setHasChanges(false);
    } catch (e) {
      console.error("Failed to load agent.yaml:", e);
    }
  }, [barrackPath]);

  useEffect(() => {
    loadConfig();
  }, [loadConfig]);

  const update = (partial: Partial<AgentConfig>) => {
    if (!config) return;
    setConfig({ ...config, ...partial });
    setHasChanges(true);
  };

  const handleSave = async () => {
    if (!barrackPath || !config) return;
    setSaving(true);
    setSaveMsg(null);
    const patched = patchAgentYamlDocument(rawConfig, config);
    if (!patched.ok) {
      setSaveMsg(`저장 실패: ${patched.failure.field} ${patched.failure.reason}`);
      setSaving(false);
      return;
    }
    try {
      await invoke("write_barrack_file", {
        barrackPath,
        filename: "agent.yaml",
        content: patched.raw,
      });
      const doc = parseAgentYamlDocument(patched.raw);
      setConfig(doc.data);
      setRawConfig(doc.raw);
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
