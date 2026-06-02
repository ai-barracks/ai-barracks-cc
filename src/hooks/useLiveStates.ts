import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { LiveState } from "../types";

interface LiveChangedPayload {
  barrackPath: string;
  path: string;
}

/**
 * session_id -> LiveState for the given barrack.
 * Refreshed on `live-changed` (this barrack only, debounced ~250ms to absorb
 * Pre/PostToolUse storms) and on the 30s `live-tick` (catches working->working_stale
 * time transitions + watch-misses, since get_live_states reads the FS directly).
 *
 * A per-effect `cancelled` flag drops late async responses after a barrack switch /
 * unmount, so a previous barrack's states never overwrite the current view.
 */
export function useLiveStates(
  barrackPath: string | undefined,
): Record<string, LiveState> {
  const [map, setMap] = useState<Record<string, LiveState>>({});

  useEffect(() => {
    if (!barrackPath) {
      setMap({}); // clear on barrack switch / none selected
      return;
    }
    let cancelled = false;
    let t: ReturnType<typeof setTimeout> | undefined;

    const refresh = async () => {
      try {
        const states = await invoke<LiveState[]>("get_live_states", {
          barrackPath,
        });
        if (cancelled) return; // stale response after switch/unmount
        const next: Record<string, LiveState> = {};
        for (const s of states) next[s.session_id] = s;
        setMap(next);
      } catch {
        if (!cancelled) setMap({}); // on failure, clear rather than show stale
      }
    };

    refresh();
    const unChanged = listen<LiveChangedPayload>("live-changed", (e) => {
      if (e.payload?.barrackPath === barrackPath) {
        if (t) clearTimeout(t);
        t = setTimeout(refresh, 250);
      }
    });
    const unTick = listen("live-tick", () => refresh());

    return () => {
      cancelled = true;
      if (t) clearTimeout(t);
      unChanged.then((f) => f());
      unTick.then((f) => f());
    };
  }, [barrackPath]);

  return map;
}
