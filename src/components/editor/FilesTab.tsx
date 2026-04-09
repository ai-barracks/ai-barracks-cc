import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { useAppStore } from "../../stores/appStore";
import { RulesEditor } from "./RulesEditor";
import { YamlFormEditor } from "./YamlFormEditor";
import type { FileInfo } from "../../types";

function RoleBadge({ role }: { role: string }) {
  const colors: Record<string, string> = {
    "직접 편집": "bg-blue-500/20 text-blue-400",
    "자동 축적": "bg-green-500/20 text-green-400",
    "aib 관리": "bg-purple-500/20 text-purple-400",
  };
  return (
    <span
      className={`text-[10px] px-1.5 py-0.5 rounded font-medium whitespace-nowrap ${colors[role] ?? "bg-gray-500/20 text-gray-400"}`}
    >
      {role}
    </span>
  );
}

export function FilesTab() {
  const { selectedBarrack, fetchBarracks, pendingConfigFile, clearPendingConfigFile } = useAppStore();
  const [files, setFiles] = useState<FileInfo[]>([]);
  const [selectedFile, setSelectedFile] = useState<FileInfo | null>(null);
  const [editContent, setEditContent] = useState("");
  const [hasChanges, setHasChanges] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveMessage, setSaveMessage] = useState<string | null>(null);

  const loadFiles = useCallback(async () => {
    if (!selectedBarrack) return;
    try {
      const result = await invoke<FileInfo[]>("get_barrack_files", {
        barrackPath: selectedBarrack.path,
      });
      setFiles(result);
      if (!selectedFile && result.length > 0) {
        setSelectedFile(result[0]);
        setEditContent(result[0].content);
      }
    } catch (e) {
      console.error("Failed to load files:", e);
    }
  }, [selectedBarrack, selectedFile]);

  useEffect(() => {
    loadFiles();
  }, [loadFiles]);

  useEffect(() => {
    if (pendingConfigFile && files.length > 0) {
      const target = files.find((f) => f.name === pendingConfigFile);
      if (target) {
        setSelectedFile(target);
        setEditContent(target.content);
        setHasChanges(false);
      }
      clearPendingConfigFile();
    }
  }, [pendingConfigFile, files, clearPendingConfigFile]);

  const handleSelectFile = (file: FileInfo) => {
    if (hasChanges) {
      if (!confirm("변경사항을 저장하지 않았습니다. 계속하시겠습니까?")) return;
    }
    setSelectedFile(file);
    setEditContent(file.content);
    setHasChanges(false);
    setSaveMessage(null);
  };

  const handleSave = async () => {
    if (!selectedFile) return;
    setSaving(true);
    setSaveMessage(null);
    try {
      await invoke("write_file", {
        filePath: selectedFile.path,
        content: editContent,
      });
      setHasChanges(false);
      setSaveMessage("저장 완료");
      // Refresh file list + barrack data (Overview reflects changes)
      const result = await invoke<FileInfo[]>("get_barrack_files", {
        barrackPath: selectedBarrack!.path,
      });
      setFiles(result);
      const updated = result.find((f) => f.name === selectedFile.name);
      if (updated) setSelectedFile(updated);
      await fetchBarracks();
      setTimeout(() => setSaveMessage(null), 2000);
    } catch (e) {
      setSaveMessage(`저장 실패: ${e}`);
    } finally {
      setSaving(false);
    }
  };

  if (!selectedBarrack) return null;

  return (
    <div className="flex h-full">
      {/* File list */}
      <div className="w-56 min-w-[224px] border-r border-cc-border p-3 space-y-1">
        {files.map((file) => (
          <button
            key={file.name}
            onClick={() => handleSelectFile(file)}
            className={`w-full text-left p-2.5 rounded-lg text-sm transition-colors ${
              selectedFile?.name === file.name
                ? "bg-cc-accent/20 border border-cc-accent/30"
                : "text-cc-text-dim hover:bg-cc-panel border border-transparent"
            }`}
          >
            <div className="flex items-center justify-between mb-0.5">
              <span className="font-medium truncate">{file.name}</span>
              <RoleBadge role={file.ownership} />
            </div>
            {file.description && (
              <p className="text-[11px] text-cc-text-muted leading-tight">
                {file.description}
              </p>
            )}
          </button>
        ))}
      </div>

      {/* RULES.md: structured editor */}
      {selectedFile?.name === "RULES.md" && <RulesEditor />}

      {/* agent.yaml: form editor */}
      {selectedFile?.name === "agent.yaml" && <YamlFormEditor />}

      {/* Other files: Editor + Preview */}
      {selectedFile && selectedFile.name !== "RULES.md" && selectedFile.name !== "agent.yaml" && (
        <div className="flex-1 flex flex-col">
          {/* Toolbar */}
          <div className="flex items-center justify-between px-4 py-2 border-b border-cc-border bg-cc-sidebar/30">
            <div className="flex items-center gap-2">
              <span className="text-sm font-medium">{selectedFile.name}</span>
              <RoleBadge role={selectedFile.ownership} />
              {hasChanges && (
                <span className="text-xs text-cc-warning">수정됨</span>
              )}
            </div>
            <div className="flex items-center gap-2">
              {saveMessage && (
                <span className="text-xs text-cc-success">{saveMessage}</span>
              )}
              <button
                onClick={handleSave}
                disabled={!hasChanges || saving}
                className="px-3 py-1 text-xs bg-cc-accent hover:bg-cc-accent-dim rounded transition-colors disabled:opacity-30 disabled:cursor-not-allowed"
              >
                {saving ? "저장 중..." : "저장"}
              </button>
            </div>
          </div>

          {/* Split view */}
          <div className="flex-1 flex overflow-hidden">
            {/* Editor */}
            <div className="w-1/2 border-r border-cc-border">
              <textarea
                value={editContent}
                onChange={(e) => {
                  setEditContent(e.target.value);
                  setHasChanges(e.target.value !== selectedFile.content);
                }}
                className="w-full h-full p-4 bg-transparent text-sm font-mono text-cc-text resize-none focus:outline-none leading-relaxed"
                spellCheck={false}
              />
            </div>

            {/* Preview */}
            <div className="w-1/2 p-4 overflow-y-auto">
              <div className="prose prose-sm max-w-none prose-headings:text-cc-text prose-p:text-cc-text-dim prose-li:text-cc-text-dim prose-strong:text-cc-text prose-code:text-cc-accent prose-code:bg-cc-panel prose-code:px-1 prose-code:rounded prose-a:text-cc-accent">
                <ReactMarkdown remarkPlugins={[remarkGfm]}>
                  {editContent}
                </ReactMarkdown>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
