import { useEffect, useMemo, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import type { SkillCard, SkillsIndex } from "../../types";

export function SkillsTab() {
  const { selectedBarrack } = useAppStore();
  const barrackPath = selectedBarrack?.path;
  const [index, setIndex] = useState<SkillsIndex | null>(null);
  const [selectedSlug, setSelectedSlug] = useState<string | null>(null);
  const [query, setQuery] = useState("");

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

  useEffect(() => {
    setSelectedSlug(null);
    setQuery("");
  }, [barrackPath]);

  const filteredSkills = useMemo(() => {
    if (!index) return [];
    const q = query.trim().toLowerCase();
    if (!q) return index.skills;
    return index.skills.filter((s) =>
      `${s.name} ${s.description}`.toLowerCase().includes(q)
    );
  }, [index, query]);

  if (!index) return null;

  return (
    <div className="flex h-full">
      {/* Left: search + cards */}
      <div className="w-64 min-w-[256px] border-r border-cc-border p-4">
        <div className="mb-3">
          <h3 className="text-xs font-medium text-cc-text-muted uppercase tracking-wider">
            Skills ({index.skills.length})
          </h3>
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
                onClick={() => setSelectedSlug(skill.slug)}
              />
            ))}
          </div>
        )}
      </div>

      {/* Right: empty for now (Task 6 fills this in) */}
      <div className="flex-1 p-6 overflow-y-auto">
        <div className="flex items-center justify-center h-full text-cc-text-muted">
          <div className="text-center">
            <div className="text-3xl mb-3">🧪</div>
            <p className="text-sm">스킬을 선택하세요</p>
          </div>
        </div>
      </div>
    </div>
  );
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
