// src/components/skills/useSkillCrud.ts
import { useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { SkillFrontmatterWrite, SkillSaveResult } from "../../types";

/**
 * Centralized Save & Sync orchestration for skills.
 *
 * Behavior:
 * - Write commands (create/update/delete/rename) throw on failure (caller catches).
 * - Sync runs after every successful write. If sync fails, the result reports `syncOk: false`
 *   with the trimmed first line of stderr — this drives the inline banner in the dialog.
 *   The disk write is never rolled back (spec §3.5).
 */
export function useSkillCrud(barrackPath: string | undefined) {
  const ensurePath = useCallback(() => {
    if (!barrackPath) throw new Error("No barrack selected.");
    return barrackPath;
  }, [barrackPath]);

  const runSync = useCallback(async (): Promise<{ syncOk: boolean; syncError?: string }> => {
    try {
      await invoke<string>("sync_barrack", { barrackPath: ensurePath(), dryRun: false });
      return { syncOk: true };
    } catch (e) {
      const msg = String(e ?? "unknown sync error").split("\n")[0].slice(0, 240);
      return { syncOk: false, syncError: msg };
    }
  }, [ensurePath]);

  const create = useCallback(async (
    slug: string,
    frontmatter: SkillFrontmatterWrite,
    body: string,
  ): Promise<SkillSaveResult> => {
    await invoke<void>("create_skill", { barrackPath: ensurePath(), slug, frontmatter, body });
    const sync = await runSync();
    return { saved: true, ...sync };
  }, [ensurePath, runSync]);

  const update = useCallback(async (
    slug: string,
    frontmatter: SkillFrontmatterWrite,
    body: string,
  ): Promise<SkillSaveResult> => {
    await invoke<void>("update_skill", { barrackPath: ensurePath(), slug, frontmatter, body });
    const sync = await runSync();
    return { saved: true, ...sync };
  }, [ensurePath, runSync]);

  const remove = useCallback(async (slug: string): Promise<SkillSaveResult> => {
    await invoke<void>("delete_skill", { barrackPath: ensurePath(), slug });
    const sync = await runSync();
    return { saved: true, ...sync };
  }, [ensurePath, runSync]);

  const rename = useCallback(async (oldSlug: string, newSlug: string): Promise<void> => {
    await invoke<void>("rename_skill", { barrackPath: ensurePath(), oldSlug, newSlug });
  }, [ensurePath]);

  /**
   * Edit transaction for slug rename + body/frontmatter update.
   * Order: rename_skill → update_skill (with new slug + frontmatter.name = new_slug) → sync.
   * If rename succeeds but update fails, the rename is NOT rolled back (spec §3.2).
   */
  const renameAndUpdate = useCallback(async (
    oldSlug: string,
    newSlug: string,
    frontmatter: SkillFrontmatterWrite,
    body: string,
  ): Promise<SkillSaveResult> => {
    await rename(oldSlug, newSlug);
    return update(newSlug, { ...frontmatter, name: newSlug }, body);
  }, [rename, update]);

  const retrySync = useCallback(async (): Promise<{ syncOk: boolean; syncError?: string }> => {
    return runSync();
  }, [runSync]);

  return { create, update, remove, rename, renameAndUpdate, retrySync };
}
