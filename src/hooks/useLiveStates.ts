import { useEffect, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { LiveState } from "../types";

/**
 * session_id -> LiveState for the given barrack.
 * Refreshed on `live-changed` (this barrack only, debounced ~250ms to absorb
 * Pre/PostToolUse storms) and on the 30s `live-tick` (catches working->working_stale
 * time transitions + watch-misses, since get_live_states reads the FS directly).
 */
export function useLiveStates(
  barrackPath: string | undefined,
): Record<string, LiveState> {
  const [map, setMap] = useState<Record<string, LiveState>>({});

  const refresh = useCallback(async (path: string) => {
    try {
      const states = await invoke<LiveState[]>("get_live_states", {
        barrackPath: path,
      });
      const next: Record<string, LiveState> = {};
      for (const s of states) next[s.session_id] = s;
      setMap(next);
    } catch {
      setMap({}); // on failure, clear rather than show stale
    }
  }, []);

  useEffect(() => {
    if (!barrackPath) {
      setMap({}); // clear on barrack switch / none selected
      return;
    }
    refresh(barrackPath);

    let t: ReturnType<typeof setTimeout> | undefined;
    const unChanged = listen<string>("live-changed", (e) => {
      if (typeof e.payload === "string" && e.payload.includes(barrackPath)) {
        if (t) clearTimeout(t);
        t = setTimeout(() => refresh(barrackPath), 250);
      }
    });
    const unTick = listen("live-tick", () => refresh(barrackPath));

    return () => {
      if (t) clearTimeout(t);
      unChanged.then((f) => f());
      unTick.then((f) => f());
    };
  }, [barrackPath, refresh]);

  return map;
}
