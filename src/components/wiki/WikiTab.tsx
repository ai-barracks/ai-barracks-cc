import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { useAppStore } from "../../stores/appStore";
import type { WikiIndex } from "../../types";

export function WikiTab() {
  const { selectedBarrack } = useAppStore();
  const [wikiIndex, setWikiIndex] = useState<WikiIndex | null>(null);
  const [selectedTopic, setSelectedTopic] = useState<string | null>(null);
  const [topicContent, setTopicContent] = useState<string>("");

  const loadWiki = useCallback(async () => {
    if (!selectedBarrack) return;
    try {
      const index = await invoke<WikiIndex>("get_wiki_index", {
        barrackPath: selectedBarrack.path,
      });
      setWikiIndex(index);
    } catch (e) {
      console.error("Failed to load wiki:", e);
    }
  }, [selectedBarrack]);

  useEffect(() => {
    loadWiki();
    setSelectedTopic(null);
    setTopicContent("");
  }, [loadWiki]);

  const handleSelectTopic = async (file: string) => {
    if (!selectedBarrack) return;
    setSelectedTopic(file);
    try {
      const content = await invoke<string>("get_wiki_topic", {
        barrackPath: selectedBarrack.path,
        topicFile: file,
      });
      setTopicContent(content);
    } catch (e) {
      setTopicContent(`Error: ${e}`);
    }
  };

  if (!wikiIndex) return null;

  return (
    <div className="flex h-full">
      {/* Topic list */}
      <div className="w-64 min-w-[256px] border-r border-cc-border p-4">
        <h3 className="text-xs font-medium text-cc-text-muted mb-3 uppercase tracking-wider">
          Topics ({wikiIndex.topics.length})
        </h3>

        {wikiIndex.topics.length > 0 ? (
          <div className="space-y-2">
            {wikiIndex.topics.map((topic) => (
              <button
                key={topic.file}
                onClick={() => handleSelectTopic(topic.file)}
                className={`w-full text-left p-3 rounded-lg border transition-colors ${
                  selectedTopic === topic.file
                    ? "bg-cc-accent/20 border-cc-accent/40"
                    : "border-cc-border hover:bg-cc-panel"
                }`}
              >
                <div className="text-sm font-medium mb-1">{topic.name}</div>
                {topic.summary && (
                  <p className="text-xs text-cc-text-muted line-clamp-2">
                    {topic.summary}
                  </p>
                )}
                <div className="text-[10px] text-cc-text-muted mt-1">
                  Updated: {topic.updated}
                </div>
              </button>
            ))}
          </div>
        ) : (
          <div className="text-xs text-cc-text-muted py-8 text-center">
            아직 위키 토픽이 없습니다
          </div>
        )}

        {/* Recent changes */}
        {wikiIndex.recent_changes.length > 0 && (
          <div className="mt-6">
            <h3 className="text-xs font-medium text-cc-text-muted mb-2 uppercase tracking-wider">
              Recent Changes
            </h3>
            <div className="space-y-1">
              {wikiIndex.recent_changes.slice(0, 5).map((change, i) => (
                <div key={i} className="text-[11px] text-cc-text-muted">
                  {change}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>

      {/* Topic content */}
      <div className="flex-1 p-6 overflow-y-auto">
        {selectedTopic ? (
          <div className="prose prose-sm max-w-none prose-headings:text-cc-text prose-p:text-cc-text-dim prose-li:text-cc-text-dim prose-strong:text-cc-text prose-code:text-cc-accent prose-code:bg-cc-panel prose-code:px-1 prose-code:rounded prose-a:text-cc-accent">
            <ReactMarkdown remarkPlugins={[remarkGfm]}>
              {topicContent}
            </ReactMarkdown>
          </div>
        ) : (
          <div className="flex items-center justify-center h-full text-cc-text-muted">
            <div className="text-center">
              <div className="text-3xl mb-3">📚</div>
              <p className="text-sm">토픽을 선택하세요</p>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
