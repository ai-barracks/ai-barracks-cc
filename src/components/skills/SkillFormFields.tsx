// src/components/skills/SkillFormFields.tsx
import { useMemo } from "react";
import type { SkillFrontmatterWrite } from "../../types";

const SLUG_REGEX = /^[a-z][a-z0-9-]*$/;
const MIN_DESCRIPTION_LEN = 20;

export interface SkillFormFieldsProps {
  slug: string;                                       // shown as readonly when editing existing skill
  slugEditable: boolean;
  onSlugChange?: (next: string) => void;              // only called when slugEditable
  frontmatter: SkillFrontmatterWrite;
  onFrontmatterChange: (next: SkillFrontmatterWrite) => void;
  syncSlugFromName: boolean;                          // true while user hasn't manually edited slug
  onUserEditedSlug?: () => void;                      // signal parent that slug-from-name sync should stop
}

export function SkillFormFields({
  slug,
  slugEditable,
  onSlugChange,
  frontmatter,
  onFrontmatterChange,
  syncSlugFromName,
  onUserEditedSlug,
}: SkillFormFieldsProps) {
  const slugError = useMemo(() => {
    if (!slug) return "slug is required";
    if (!SLUG_REGEX.test(slug)) return "slug must be kebab-case (a-z, 0-9, -; start with a letter)";
    return null;
  }, [slug]);

  const descLen = frontmatter.description.length;
  const descError = useMemo(() => {
    if (!frontmatter.description) return "description is required";
    if (descLen < MIN_DESCRIPTION_LEN) {
      return `description must be at least ${MIN_DESCRIPTION_LEN} chars (currently ${descLen})`;
    }
    return null;
  }, [frontmatter.description, descLen]);

  const handleNameChange = (next: string) => {
    onFrontmatterChange({ ...frontmatter, name: next });
    if (syncSlugFromName && slugEditable && onSlugChange) {
      const auto = next.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "");
      onSlugChange(auto);
    }
  };

  const handleField = (key: keyof SkillFrontmatterWrite) => (e: React.ChangeEvent<HTMLInputElement>) => {
    onFrontmatterChange({ ...frontmatter, [key]: e.target.value || undefined });
  };

  // Custom field add/remove
  const customEntries = Object.entries(frontmatter.custom ?? {});
  const addCustomField = () => {
    const key = prompt("Custom field key (lowercase, no spaces):");
    if (!key || !/^[a-zA-Z][\w-]*$/.test(key)) {
      if (key) alert("Invalid key. Use letters, numbers, _ or -, starting with a letter.");
      return;
    }
    onFrontmatterChange({ ...frontmatter, custom: { ...(frontmatter.custom ?? {}), [key]: "" } });
  };
  const removeCustomField = (key: string) => {
    const next = { ...(frontmatter.custom ?? {}) };
    delete next[key];
    onFrontmatterChange({ ...frontmatter, custom: next });
  };
  const setCustomValue = (key: string, value: string) => {
    onFrontmatterChange({ ...frontmatter, custom: { ...(frontmatter.custom ?? {}), [key]: value } });
  };

  return (
    <div className="space-y-3">
      <FieldRow label="slug *" error={slugError}>
        <input
          type="text"
          className="w-full bg-zinc-800 px-2 py-1 rounded text-sm font-mono"
          value={slug}
          disabled={!slugEditable}
          onChange={(e) => {
            onSlugChange?.(e.target.value);
            onUserEditedSlug?.();
          }}
        />
      </FieldRow>
      <FieldRow label="name *">
        <input
          type="text"
          className="w-full bg-zinc-800 px-2 py-1 rounded text-sm"
          value={frontmatter.name}
          onChange={(e) => handleNameChange(e.target.value)}
        />
      </FieldRow>
      <FieldRow label="description *" error={descError}>
        <textarea
          className="w-full bg-zinc-800 px-2 py-1 rounded text-sm"
          rows={3}
          value={frontmatter.description}
          onChange={(e) => onFrontmatterChange({ ...frontmatter, description: e.target.value })}
        />
        <div className="text-xs text-zinc-400 mt-1">{descLen} chars (min {MIN_DESCRIPTION_LEN})</div>
      </FieldRow>
      <FieldRow label="argument-hint">
        <input
          type="text"
          className="w-full bg-zinc-800 px-2 py-1 rounded text-sm font-mono"
          value={frontmatter["argument-hint"] ?? ""}
          onChange={(e) => onFrontmatterChange({ ...frontmatter, "argument-hint": e.target.value || undefined })}
        />
      </FieldRow>
      <FieldRow label="allowed-tools">
        <input
          type="text"
          className="w-full bg-zinc-800 px-2 py-1 rounded text-sm font-mono"
          value={frontmatter["allowed-tools"] ?? ""}
          onChange={(e) => onFrontmatterChange({ ...frontmatter, "allowed-tools": e.target.value || undefined })}
        />
      </FieldRow>
      <FieldRow label="aib_version">
        <input
          type="text"
          className="w-full bg-zinc-800 px-2 py-1 rounded text-sm"
          value={frontmatter.aib_version ?? "1.1"}
          onChange={handleField("aib_version")}
        />
      </FieldRow>
      <FieldRow label="upstream">
        <input
          type="text"
          className="w-full bg-zinc-800 px-2 py-1 rounded text-sm"
          value={frontmatter.upstream ?? ""}
          onChange={handleField("upstream")}
        />
      </FieldRow>
      <FieldRow label="growth_origin">
        <select
          className="w-full bg-zinc-800 px-2 py-1 rounded text-sm"
          value={frontmatter.growth_origin ?? "manual"}
          onChange={(e) => onFrontmatterChange({ ...frontmatter, growth_origin: e.target.value })}
        >
          <option value="manual">manual</option>
          <option value="growth-auto-generated">growth-auto-generated</option>
        </select>
      </FieldRow>
      {customEntries.length > 0 && (
        <div className="border-t border-zinc-700 pt-2">
          <div className="text-xs text-zinc-400 mb-2">Custom fields</div>
          {customEntries.map(([key, val]) => (
            <FieldRow key={key} label={key}>
              <div className="flex gap-2">
                <input
                  type="text"
                  className="flex-1 bg-zinc-800 px-2 py-1 rounded text-sm"
                  value={String(val ?? "")}
                  onChange={(e) => setCustomValue(key, e.target.value)}
                />
                <button
                  type="button"
                  className="px-2 text-zinc-400 hover:text-zinc-200"
                  onClick={() => removeCustomField(key)}
                  aria-label={`remove custom field ${key}`}
                >
                  ×
                </button>
              </div>
            </FieldRow>
          ))}
        </div>
      )}
      <button type="button" className="text-sm text-blue-400 hover:underline" onClick={addCustomField}>
        + add custom field
      </button>
    </div>
  );
}

function FieldRow({ label, children, error }: { label: string; children: React.ReactNode; error?: string | null }) {
  return (
    <div>
      <label className="block text-xs text-zinc-400 mb-1">{label}</label>
      {children}
      {error && <div className="text-xs text-red-400 mt-1">{error}</div>}
    </div>
  );
}

export function isFormValid(slug: string, frontmatter: SkillFrontmatterWrite): boolean {
  return SLUG_REGEX.test(slug) && !!frontmatter.name && frontmatter.description.length >= MIN_DESCRIPTION_LEN;
}
