// src/components/skills/SkillEditorDialog.tsx
import { useEffect, useState, useMemo, useCallback } from "react";
import type { SkillFrontmatterWrite, SkillSaveResult, SkillEditorMode } from "../../types";
import { SkillFormFields, isFormValid } from "./SkillFormFields";
import { useSkillCrud } from "./useSkillCrud";

export interface SkillEditorDialogProps {
  mode: "create" | "edit";
  barrackPath: string;
  // For edit mode:
  initialSlug?: string;
  initialFrontmatter?: SkillFrontmatterWrite;
  initialBody?: string;
  onClose: () => void;
  onSaved: (savedSlug: string) => void;  // parent refreshes catalog
}

const EMPTY_FM: SkillFrontmatterWrite = {
  name: "",
  description: "",
  aib_version: "1.1",
  growth_origin: "manual",
};

export function SkillEditorDialog(props: SkillEditorDialogProps) {
  const { mode, barrackPath, onClose, onSaved } = props;
  const crud = useSkillCrud(barrackPath);

  const [slug, setSlug] = useState(props.initialSlug ?? "");
  const [slugEditable, setSlugEditable] = useState(mode === "create");
  const [syncSlugFromName, setSyncSlugFromName] = useState(mode === "create");
  const [frontmatter, setFrontmatter] = useState<SkillFrontmatterWrite>(
    props.initialFrontmatter ?? EMPTY_FM
  );
  const [body, setBody] = useState(props.initialBody ?? "");
  const [editorMode, setEditorMode] = useState<SkillEditorMode>(() => {
    // For Edit mode, attempt to detect parse failure of initial frontmatter; fall back to raw if invalid.
    if (mode === "edit" && props.initialFrontmatter && !props.initialFrontmatter.name) {
      return "raw";  // unparseable from prior raw nuclear save (spec §3.4)
    }
    return "form";
  });
  const [rawText, setRawText] = useState(() => assembleRaw(frontmatter, body));
  const [rawOverride, setRawOverride] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveResult, setSaveResult] = useState<SkillSaveResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Recompute raw preview when form changes (and override is off)
  useEffect(() => {
    if (editorMode === "form" && !rawOverride) {
      setRawText(assembleRaw(frontmatter, body));
    }
  }, [frontmatter, body, editorMode, rawOverride]);

  const formValid = useMemo(() => isFormValid(slug, frontmatter), [slug, frontmatter]);
  const canSave = !saving && (editorMode === "raw" ? rawText.length > 0 : formValid);

  const handleOverrideWithRaw = () => {
    if (!confirm("Switching to raw mode disables the form. You will edit YAML frontmatter directly. Form values may not parse back. Continue?")) {
      return;
    }
    setRawOverride(true);
    setEditorMode("raw");
  };

  const handleSave = useCallback(async () => {
    setSaving(true);
    setError(null);
    setSaveResult(null);
    try {
      let fm = frontmatter;
      let bodyToSave = body;
      if (editorMode === "raw" && rawOverride) {
        // Try to parse raw back to (frontmatter, body). On parse failure, abort with error.
        const parsed = tryParseRaw(rawText);
        if (parsed === null) {
          setError("Raw text could not be parsed (frontmatter requires `name` and `description` keys at minimum). Fix YAML and retry.");
          setSaving(false);
          return;
        }
        fm = parsed.frontmatter;
        bodyToSave = parsed.body;
      }

      let result: SkillSaveResult;
      if (mode === "create") {
        result = await crud.create(slug, fm, bodyToSave);
      } else {
        const initialSlug = props.initialSlug!;
        if (initialSlug !== slug) {
          // Slug changed → rename + update transaction
          result = await crud.renameAndUpdate(initialSlug, slug, fm, bodyToSave);
        } else {
          result = await crud.update(slug, fm, bodyToSave);
        }
      }

      setSaveResult(result);
      if (result.syncOk) {
        onSaved(slug);
        onClose();
      }
      // else: keep dialog open with banner showing
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  }, [mode, slug, frontmatter, body, editorMode, rawOverride, rawText, crud, onSaved, onClose, props.initialSlug]);

  const handleRetrySync = useCallback(async () => {
    setSaving(true);
    const r = await crud.retrySync();
    setSaving(false);
    if (r.syncOk) {
      setSaveResult({ saved: true, syncOk: true });
      onSaved(slug);
      onClose();
    } else {
      setSaveResult({ saved: true, syncOk: false, syncError: r.syncError });
    }
  }, [crud, onSaved, onClose, slug]);

  return (
    <div className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center" role="dialog" aria-modal="true">
      <div className="bg-zinc-900 border border-zinc-700 rounded-lg w-[720px] max-h-[90vh] flex flex-col">
        <div className="px-4 py-3 border-b border-zinc-700 flex items-center justify-between">
          <h2 className="text-base font-medium">{mode === "create" ? "New Skill" : `Edit Skill: ${props.initialSlug}`}</h2>
          <div className="flex items-center gap-3 text-sm">
            <label>
              <input type="radio" checked={editorMode === "form"} onChange={() => setEditorMode("form")} disabled={rawOverride} />
              <span className="ml-1">Form</span>
            </label>
            <label>
              <input type="radio" checked={editorMode === "raw"} onChange={() => setEditorMode("raw")} />
              <span className="ml-1">Raw</span>
            </label>
            {editorMode === "raw" && !rawOverride && (
              <button type="button" className="text-xs text-blue-400 hover:underline" onClick={handleOverrideWithRaw}>
                Override with raw
              </button>
            )}
          </div>
        </div>
        <div className="flex-1 overflow-y-auto p-4">
          {mode === "edit" && !slugEditable && (
            <div className="mb-3">
              <button type="button" className="text-xs text-blue-400 hover:underline"
                onClick={() => {
                  if (confirm("Renaming will move skills/<old>/ → skills/<new>/ and update frontmatter `name`. Continue?")) {
                    setSlugEditable(true);
                    setSyncSlugFromName(false);
                  }
                }}>
                [Rename slug]
              </button>
            </div>
          )}
          {editorMode === "form" ? (
            <>
              <SkillFormFields
                slug={slug}
                slugEditable={slugEditable}
                onSlugChange={setSlug}
                frontmatter={frontmatter}
                onFrontmatterChange={setFrontmatter}
                syncSlugFromName={syncSlugFromName}
                onUserEditedSlug={() => setSyncSlugFromName(false)}
              />
              <div className="mt-4">
                <label className="block text-xs text-zinc-400 mb-1">Body (markdown)</label>
                <textarea
                  className="w-full bg-zinc-800 px-2 py-2 rounded text-sm font-mono"
                  rows={12}
                  value={body}
                  onChange={(e) => setBody(e.target.value)}
                  placeholder="# Skill Title&#10;&#10;## When to invoke&#10;..."
                />
                {body.trim().length === 0 && (
                  <div className="text-xs text-yellow-400 mt-1">
                    body is empty — agents read SKILL.md body as instructions; consider adding when/how/examples.
                  </div>
                )}
              </div>
            </>
          ) : (
            <>
              <textarea
                readOnly={!rawOverride}
                className={`w-full bg-zinc-800 px-2 py-2 rounded text-sm font-mono ${rawOverride ? "" : "opacity-80"}`}
                rows={24}
                value={rawText}
                onChange={(e) => rawOverride && setRawText(e.target.value)}
              />
              {!rawOverride && (
                <div className="text-xs text-zinc-400 mt-1">Read-only preview. Click "Override with raw" to edit.</div>
              )}
            </>
          )}
          {saveResult && saveResult.syncOk === false && (
            <div className="mt-4 p-3 bg-yellow-900/30 border border-yellow-700/60 rounded">
              <div className="text-sm">✓ Saved. ⚠ aib sync failed:</div>
              <div className="text-xs font-mono text-yellow-300 mt-1 break-all">{saveResult.syncError}</div>
              <div className="mt-2 flex gap-2">
                <button type="button" className="text-xs px-2 py-1 bg-yellow-800 rounded hover:bg-yellow-700" onClick={handleRetrySync}>Retry sync</button>
                <button type="button" className="text-xs px-2 py-1 bg-zinc-700 rounded hover:bg-zinc-600" onClick={() => { setSaveResult(null); onClose(); }}>Dismiss & close</button>
              </div>
            </div>
          )}
          {error && (
            <div className="mt-4 p-3 bg-red-900/30 border border-red-700/60 rounded text-xs text-red-300">
              {error}
            </div>
          )}
        </div>
        <div className="px-4 py-3 border-t border-zinc-700 flex justify-end gap-2">
          <button type="button" className="px-3 py-1 text-sm bg-zinc-700 rounded hover:bg-zinc-600" onClick={onClose} disabled={saving}>Cancel</button>
          <button type="button" className="px-3 py-1 text-sm bg-blue-600 rounded hover:bg-blue-500 disabled:opacity-50" onClick={handleSave} disabled={!canSave}>
            {saving ? "Saving..." : "Save & Sync"}
          </button>
        </div>
      </div>
    </div>
  );
}

function assembleRaw(fm: SkillFrontmatterWrite, body: string): string {
  // Best-effort raw preview. The backend's render_frontmatter_yaml is the source of truth;
  // this is just for display.
  const lines: string[] = ["---"];
  if (fm.name) lines.push(`name: ${fm.name}`);
  if (fm.description) lines.push(`description: ${JSON.stringify(fm.description)}`);
  if (fm["argument-hint"]) lines.push(`argument-hint: ${JSON.stringify(fm["argument-hint"])}`);
  if (fm["allowed-tools"]) lines.push(`allowed-tools: ${fm["allowed-tools"]}`);
  if (fm.aib_version) lines.push(`aib_version: ${JSON.stringify(fm.aib_version)}`);
  if (fm.upstream) lines.push(`upstream: ${JSON.stringify(fm.upstream)}`);
  if (fm.growth_origin) lines.push(`growth_origin: ${fm.growth_origin}`);
  for (const [k, v] of Object.entries(fm.custom ?? {})) {
    lines.push(`${k}: ${typeof v === "string" ? v : JSON.stringify(v)}`);
  }
  lines.push("---", "", body);
  return lines.join("\n");
}

function tryParseRaw(raw: string): { frontmatter: SkillFrontmatterWrite; body: string } | null {
  // Minimal YAML splitter — full YAML semantics handled by backend roundtrip.
  // We reject unless we can recover at least a `name:` and `description:` line.
  const m = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return null;
  const fmText = m[1];
  const body = m[2] ?? "";
  const fm: SkillFrontmatterWrite = { name: "", description: "" };
  for (const line of fmText.split(/\r?\n/)) {
    const kv = line.match(/^([a-zA-Z0-9_-]+):\s*(.*)$/);
    if (!kv) continue;
    const [, key, val] = kv;
    const stripped = val.replace(/^"(.*)"$/, "$1");
    if (key === "name") fm.name = stripped;
    else if (key === "description") fm.description = stripped;
    else if (key === "argument-hint") fm["argument-hint"] = stripped;
    else if (key === "allowed-tools") fm["allowed-tools"] = stripped;
    else if (key === "aib_version") fm.aib_version = stripped;
    else if (key === "upstream") fm.upstream = stripped;
    else if (key === "growth_origin") fm.growth_origin = stripped;
    else fm.custom = { ...(fm.custom ?? {}), [key]: stripped };
  }
  if (!fm.name || !fm.description) return null;
  return { frontmatter: fm, body };
}
