// src/components/skills/SkillDeleteDialog.tsx
import { useState, useCallback } from "react";
import { useSkillCrud } from "./useSkillCrud";

export interface SkillDeleteDialogProps {
  barrackPath: string;
  slug: string;
  onClose: () => void;
  onDeleted: () => void;
}

export function SkillDeleteDialog({ barrackPath, slug, onClose, onDeleted }: SkillDeleteDialogProps) {
  const crud = useSkillCrud(barrackPath);
  const [confirmText, setConfirmText] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [syncFailure, setSyncFailure] = useState<string | null>(null);

  const canDelete = confirmText === slug && !deleting;

  const handleDelete = useCallback(async () => {
    setDeleting(true);
    setError(null);
    try {
      const r = await crud.remove(slug);
      if (r.syncOk) {
        onDeleted();
        onClose();
      } else {
        setSyncFailure(r.syncError ?? "unknown sync error");
      }
    } catch (e) {
      setError(String(e));
    } finally {
      setDeleting(false);
    }
  }, [crud, slug, onDeleted, onClose]);

  const handleRetry = useCallback(async () => {
    setDeleting(true);
    const r = await crud.retrySync();
    setDeleting(false);
    if (r.syncOk) {
      onDeleted();
      onClose();
    } else {
      setSyncFailure(r.syncError ?? "unknown sync error");
    }
  }, [crud, onDeleted, onClose]);

  return (
    <div className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center" role="dialog" aria-modal="true">
      <div className="bg-zinc-900 border border-zinc-700 rounded-lg w-[480px] flex flex-col">
        <div className="px-4 py-3 border-b border-zinc-700">
          <h2 className="text-base font-medium">Delete skill '{slug}'?</h2>
        </div>
        <div className="p-4 space-y-3">
          <div className="text-sm text-zinc-300">
            This removes <code className="bg-zinc-800 px-1 rounded">skills/{slug}/</code> recursively
            (including SKILL.md, scripts/, references/).
          </div>
          <div>
            <label className="block text-xs text-zinc-400 mb-1">Type the slug to confirm:</label>
            <input
              type="text"
              className="w-full bg-zinc-800 px-2 py-1 rounded text-sm font-mono"
              value={confirmText}
              onChange={(e) => setConfirmText(e.target.value)}
              autoFocus
            />
          </div>
          {syncFailure && (
            <div className="p-3 bg-yellow-900/30 border border-yellow-700/60 rounded text-xs">
              ✓ Deleted from disk. ⚠ aib sync failed: <span className="font-mono text-yellow-300">{syncFailure}</span>
              <div className="mt-2 flex gap-2">
                <button type="button" className="px-2 py-1 bg-yellow-800 rounded hover:bg-yellow-700" onClick={handleRetry}>Retry sync</button>
                <button type="button" className="px-2 py-1 bg-zinc-700 rounded hover:bg-zinc-600" onClick={() => { onDeleted(); onClose(); }}>Dismiss & close</button>
              </div>
            </div>
          )}
          {error && <div className="text-xs text-red-300">{error}</div>}
        </div>
        <div className="px-4 py-3 border-t border-zinc-700 flex justify-end gap-2">
          <button type="button" className="px-3 py-1 text-sm bg-zinc-700 rounded hover:bg-zinc-600" onClick={onClose} disabled={deleting}>Cancel</button>
          <button type="button" className="px-3 py-1 text-sm bg-red-600 rounded hover:bg-red-500 disabled:opacity-50" onClick={handleDelete} disabled={!canDelete}>
            {deleting ? "Deleting..." : "Delete"}
          </button>
        </div>
      </div>
    </div>
  );
}
