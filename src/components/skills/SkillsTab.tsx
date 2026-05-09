import { useEffect, useMemo, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { useAppStore } from "../../stores/appStore";
import type { SkillCard, SkillsIndex, SkillFrontmatterWrite } from "../../types";
import { SkillEditorDialog } from "./SkillEditorDialog";
import { SkillDeleteDialog } from "./SkillDeleteDialog";

export function SkillsTab() {
  const { selectedBarrack } = useAppStore();
  const barrackPath = selectedBarrack?.path;
  const [index, setIndex] = useState<SkillsIndex | null>(null);
  const [selectedSlug, setSelectedSlug] = useState<string | null>(null);
  const [content, setContent] = useState<string>("");
  const selectedCard = useMemo(
    () => index?.skills.find((s) => s.slug === selectedSlug) ?? null,
    [index, selectedSlug]
  );
  const [query, setQuery] = useState("");

  // CRUD dialog state (Task 12)
  const [editorOpen, setEditorOpen] = useState<
    { mode: "create" } | { mode: "edit"; slug: string } | null
  >(null);
  const [deleteOpen, setDeleteOpen] = useState<string | null>(null);
  const [editorInitial, setEditorInitial] = useState<
    { frontmatter: SkillFrontmatterWrite; body: string } | null
  >(null);
  const [aibVersion, setAibVersion] = useState<string | null>(null);

  const loadIndex = useCallback(async () => {
    if (!barrackPath) return;
    try {
      const idx = await invoke<SkillsIndex>("get_skills_index", { barrackPath });
      setIndex(idx);
    } catch (e) {
      console.error("Failed to load skills:", e);
      setIndex({ skills: [], skills_dir_exists: false });
    }
  }, [barrackPath]);

  useEffect(() => {
    loadIndex();
  }, [loadIndex]);

  // aib version banner (Task 12 — backend get_cli_version takes no args; returns stripped "0.8.2"-style)
  useEffect(() => {
    invoke<string>("get_cli_version")
      .then(setAibVersion)
      .catch(() => setAibVersion("unknown"));
  }, []);

  const openEditor = useCallback(
    async (slug: string) => {
      if (!barrackPath) return;
      try {
        const raw = await invoke<string>("get_skill_content", { barrackPath, slug });
        const m = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
        const fm: SkillFrontmatterWrite = { name: slug, description: "" };
        let body = raw;
        if (m) {
          body = m[2] ?? "";
          for (const line of m[1].split(/\r?\n/)) {
            const kv = line.match(/^([a-zA-Z0-9_-]+):\s*(.*)$/);
            if (!kv) continue;
            const [, k, v] = kv;
            const val = v.replace(/^"(.*)"$/, "$1");
            if (k === "name") fm.name = val;
            else if (k === "description") fm.description = val;
            else if (k === "argument-hint") fm["argument-hint"] = val;
            else if (k === "allowed-tools") fm["allowed-tools"] = val;
            else if (k === "aib_version") fm.aib_version = val;
            else if (k === "upstream") fm.upstream = val;
            else if (k === "growth_origin") fm.growth_origin = val;
            else fm.custom = { ...(fm.custom ?? {}), [k]: val };
          }
        }
        setEditorInitial({ frontmatter: fm, body });
        setEditorOpen({ mode: "edit", slug });
      } catch (e) {
        console.error("Failed to load skill for edit:", e);
        alert("Failed to load skill content. See console.");
      }
    },
    [barrackPath]
  );

  useEffect(() => {
    setSelectedSlug(null);
    setQuery("");
    setContent("");
  }, [barrackPath]);

  const handleSelect = useCallback(
    async (slug: string) => {
      setSelectedSlug(slug);
      if (!barrackPath) return;
      try {
        const body = await invoke<string>("get_skill_content", {
          barrackPath,
          slug,
        });
        // Race guard: 이 invoke가 시작된 후 사용자가 다른 카드를 선택했으면 무시.
        setSelectedSlug((cur) => {
          if (cur === slug) setContent(body);
          return cur;
        });
      } catch (e) {
        setSelectedSlug((cur) => {
          if (cur === slug) setContent(`Error: ${e}`);
          return cur;
        });
      }
    },
    [barrackPath]
  );

  const filteredSkills = useMemo(() => {
    if (!index) return [];
    const q = query.trim().toLowerCase();
    if (!q) return index.skills;
    return index.skills.filter((s) =>
      `${s.name} ${s.description}`.toLowerCase().includes(q)
    );
  }, [index, query]);

  if (!index) return null;

  const aibTooOld =
    aibVersion !== null && aibVersion !== "unknown" && parseAibSemver(aibVersion) < 0x010200;

  return (
    <div className="flex flex-col h-full">
      {aibTooOld && (
        <div className="px-3 py-2 bg-yellow-900/40 border-b border-yellow-700/60 text-xs">
          설치된 aib 버전: <span className="font-mono">{aibVersion}</span>. Skills 등록은 aib v1.2.0+가
          필요합니다.{" "}
          <code className="bg-zinc-800 px-1 ml-1 rounded">brew upgrade ai-barracks</code> 후 앱을
          재시작하세요.
        </div>
      )}
      <div className="flex flex-1 min-h-0">
      {/* Left: search + cards */}
      <div className="w-64 min-w-[256px] border-r border-cc-border p-4 flex flex-col min-h-0">
        <div className="mb-3 flex items-center justify-between gap-2">
          <h3 className="text-xs font-medium text-cc-text-muted uppercase tracking-wider">
            Skills ({index.skills.length})
          </h3>
          <button
            type="button"
            className="px-2 py-1 text-xs bg-blue-600 rounded hover:bg-blue-500 disabled:opacity-50"
            onClick={() => {
              setEditorInitial(null);
              setEditorOpen({ mode: "create" });
            }}
            disabled={!barrackPath}
          >
            + New Skill
          </button>
        </div>
        <input
          type="search"
          placeholder="검색..."
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          className="w-full mb-3 px-2 py-1 text-xs bg-cc-panel border border-cc-border rounded focus:outline-none focus:border-cc-accent"
        />

        {!index.skills_dir_exists ? (
          <div className="text-xs text-cc-text-muted py-8 text-center">
            이 배럭에는 Skills가 없습니다.
            <br />
            <code className="text-[10px]">aib sync</code>로 시드를 받으세요.
          </div>
        ) : filteredSkills.length === 0 ? (
          <div className="text-xs text-cc-text-muted py-4 text-center">
            {query ? "검색 결과 없음" : "skills 디렉터리에서 SKILL.md를 찾지 못했습니다"}
          </div>
        ) : (
          <div className="space-y-2">
            {filteredSkills.map((skill) => (
              <SkillCardItem
                key={skill.slug}
                skill={skill}
                selected={selectedSlug === skill.slug}
                onClick={() => handleSelect(skill.slug)}
              />
            ))}
          </div>
        )}
      </div>

      <div className="flex-1 p-6 overflow-y-auto">
        {selectedCard ? (
          <div className="space-y-4">
            {/* Meta box */}
            <div className="border border-cc-border rounded-lg p-4 bg-cc-panel/40">
              <div className="flex items-start justify-between gap-2 mb-1">
                <div className="text-base font-semibold">{selectedCard.name}</div>
                <div className="flex gap-2 shrink-0">
                  <button
                    type="button"
                    className="px-2 py-1 text-xs bg-zinc-700 rounded hover:bg-zinc-600"
                    onClick={() => openEditor(selectedCard.slug)}
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    className="px-2 py-1 text-xs bg-red-700 rounded hover:bg-red-600"
                    onClick={() => setDeleteOpen(selectedCard.slug)}
                  >
                    Delete
                  </button>
                </div>
              </div>
              {selectedCard.description && (
                <p className="text-sm text-cc-text-dim mb-3">{selectedCard.description}</p>
              )}
              <dl className="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 text-xs text-cc-text-muted">
                <dt>slug</dt>
                <dd className="font-mono text-cc-text-dim">{selectedCard.slug}</dd>
                {selectedCard.aib_version && (
                  <>
                    <dt>aib_version</dt>
                    <dd className="font-mono text-cc-text-dim">{selectedCard.aib_version}</dd>
                  </>
                )}
                {selectedCard.upstream && (
                  <>
                    <dt>upstream</dt>
                    <dd className="font-mono text-cc-text-dim break-all">{selectedCard.upstream}</dd>
                  </>
                )}
                {selectedCard.argument_hint && (
                  <>
                    <dt>argument-hint</dt>
                    <dd className="font-mono text-cc-text-dim">{selectedCard.argument_hint}</dd>
                  </>
                )}
                {selectedCard.parse_error && (
                  <>
                    <dt className="text-red-400">parse_error</dt>
                    <dd className="text-red-400">{selectedCard.parse_error}</dd>
                  </>
                )}
              </dl>
            </div>

            {/* Body */}
            <div className="prose prose-sm max-w-none prose-headings:text-cc-text prose-p:text-cc-text-dim prose-li:text-cc-text-dim prose-strong:text-cc-text prose-code:text-cc-accent prose-code:bg-cc-panel prose-code:px-1 prose-code:rounded prose-a:text-cc-accent">
              <ReactMarkdown remarkPlugins={[remarkGfm]}>{content}</ReactMarkdown>
            </div>
          </div>
        ) : (
          <div className="flex items-center justify-center h-full text-cc-text-muted">
            <div className="text-center">
              <div className="text-3xl mb-3">🧪</div>
              <p className="text-sm">스킬을 선택하세요</p>
            </div>
          </div>
        )}
      </div>
      </div>
      {editorOpen && barrackPath && (
        <SkillEditorDialog
          mode={editorOpen.mode}
          barrackPath={barrackPath}
          initialSlug={editorOpen.mode === "edit" ? editorOpen.slug : undefined}
          initialFrontmatter={editorInitial?.frontmatter}
          initialBody={editorInitial?.body}
          onClose={() => {
            setEditorOpen(null);
            setEditorInitial(null);
          }}
          onSaved={(savedSlug) => {
            loadIndex();
            setSelectedSlug(savedSlug);
          }}
        />
      )}
      {deleteOpen && barrackPath && (
        <SkillDeleteDialog
          barrackPath={barrackPath}
          slug={deleteOpen}
          onClose={() => setDeleteOpen(null)}
          onDeleted={() => {
            setDeleteOpen(null);
            if (selectedSlug === deleteOpen) setSelectedSlug(null);
            loadIndex();
          }}
        />
      )}
    </div>
  );
}

// Accepts "aib v1.2.0", "v1.2.0", or "1.2.0" → returns 0xMMmmpp packed
// (e.g. 1.2.0 → 0x010200) so we can compare with arithmetic ordering.
function parseAibSemver(v: string): number {
  const m = v.match(/(\d+)\.(\d+)\.(\d+)/);
  if (!m) return 0;
  return (parseInt(m[1], 10) << 16) | (parseInt(m[2], 10) << 8) | parseInt(m[3], 10);
}

function SkillCardItem({
  skill,
  selected,
  onClick,
}: {
  skill: SkillCard;
  selected: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className={`w-full text-left p-3 rounded-lg border transition-colors ${
        selected
          ? "bg-cc-accent/20 border-cc-accent/40"
          : "border-cc-border hover:bg-cc-panel"
      }`}
    >
      <div className="flex items-start justify-between gap-2 mb-1">
        <div className="text-sm font-medium">{skill.name}</div>
        {skill.parse_error && (
          <span title={skill.parse_error} className="text-xs">
            ⚠️
          </span>
        )}
      </div>
      {skill.description && (
        <p className="text-xs text-cc-text-muted line-clamp-2 mb-1">
          {skill.description}
        </p>
      )}
      <div className="flex flex-wrap gap-1 text-[10px] text-cc-text-muted">
        {skill.aib_version && <span>aib {skill.aib_version}</span>}
        {skill.upstream && <span>· upstream</span>}
        {skill.argument_hint && (
          <span className="truncate max-w-full">· args: {skill.argument_hint}</span>
        )}
      </div>
    </button>
  );
}
