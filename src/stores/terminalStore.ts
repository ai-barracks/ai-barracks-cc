import { create } from "zustand";
import type { TerminalSession, TerminalSettings, QuickCommand, SplitLayout } from "../types";

const DEFAULT_SETTINGS: TerminalSettings = {
  fontFamily: "SF Mono, Menlo, Monaco, Consolas, monospace",
  fontSize: 14,
  lineHeight: 1.2,
  cursorStyle: "bar",
};

function loadSettings(): TerminalSettings {
  const saved = localStorage.getItem("cc-terminal-settings");
  if (!saved) return DEFAULT_SETTINGS;
  try {
    return { ...DEFAULT_SETTINGS, ...JSON.parse(saved) };
  } catch {
    return DEFAULT_SETTINGS;
  }
}

function loadPanelWidths(): Record<string, number> {
  const saved = localStorage.getItem("cc-terminal-panel-widths");
  if (!saved) return {};
  try {
    return JSON.parse(saved);
  } catch {
    return {};
  }
}

function loadSplitLayouts(): Record<string, SplitLayout> {
  const saved = localStorage.getItem("cc-terminal-split-layouts");
  if (!saved) return {};
  try {
    return JSON.parse(saved);
  } catch {
    return {};
  }
}

function loadQuickCommands(): QuickCommand[] {
  const saved = localStorage.getItem("cc-quick-commands");
  if (!saved) return [];
  try {
    return JSON.parse(saved);
  } catch {
    return [];
  }
}

function loadPersistedSessions(): TerminalSession[] {
  const saved = localStorage.getItem("cc-terminal-sessions");
  if (!saved) return [];
  try { return JSON.parse(saved); } catch { return []; }
}

function persistSessions(sessions: TerminalSession[]) {
  localStorage.setItem("cc-terminal-sessions", JSON.stringify(sessions));
}

// Global output buffer registry (not in Zustand to avoid re-renders)
const outputBuffers = new Map<string, string[]>();
const MAX_BUFFER_LINES = 5000;

export function appendToBuffer(sessionId: string, data: string) {
  let buf = outputBuffers.get(sessionId);
  if (!buf) {
    buf = [];
    outputBuffers.set(sessionId, buf);
  }
  buf.push(data);
  if (buf.length > MAX_BUFFER_LINES) {
    buf.splice(0, buf.length - MAX_BUFFER_LINES);
  }
}

export function getBuffer(sessionId: string): string {
  const buf = outputBuffers.get(sessionId);
  if (!buf) return "";
  return buf.join("").replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

export function clearBuffer(sessionId: string) {
  outputBuffers.delete(sessionId);
}

const DEFAULT_PANEL_WIDTH = 480;

interface TerminalState {
  sessions: TerminalSession[];
  activeTerminalPerBarrack: Record<string, string>;
  panelWidthPerBarrack: Record<string, number>;
  splitLayoutPerBarrack: Record<string, SplitLayout>;
  settings: TerminalSettings;
  quickCommands: QuickCommand[];
  isResizing: boolean;

  addSession: (session: TerminalSession) => void;
  removeSession: (id: string) => void;
  setActiveTerminal: (barrackPath: string, id: string) => void;
  setPtyId: (sessionId: string, ptyId: string) => void;
  setPanelWidth: (barrackPath: string, w: number) => void;
  setSplitLayout: (barrackPath: string, layout: SplitLayout) => void;
  setSlotTerminal: (barrackPath: string, slotIndex: number, sessionId: string | null) => void;
  setIsResizing: (v: boolean) => void;
  updateSettings: (partial: Partial<TerminalSettings>) => void;
  addQuickCommand: (cmd: QuickCommand) => void;
  removeQuickCommand: (id: string) => void;
  markExited: (id: string) => void;
  reconnectSessions: (survivingPtyIds: Set<string>) => void;
}

export const useTerminalStore = create<TerminalState>((set, get) => ({
  sessions: [],
  activeTerminalPerBarrack: {},
  panelWidthPerBarrack: loadPanelWidths(),
  splitLayoutPerBarrack: loadSplitLayouts(),
  settings: loadSettings(),
  quickCommands: loadQuickCommands(),
  isResizing: false,

  addSession: (session) =>
    set((s) => {
      const next = [...s.sessions, session];
      persistSessions(next);

      // Auto-fill empty slot in split/grid mode
      const layout = s.splitLayoutPerBarrack[session.barrackPath];
      let nextLayouts = s.splitLayoutPerBarrack;
      if (layout && layout.mode !== "single") {
        const emptyIdx = layout.slots.indexOf(null);
        if (emptyIdx !== -1) {
          const newSlots = [...layout.slots];
          newSlots[emptyIdx] = session.id;
          nextLayouts = {
            ...s.splitLayoutPerBarrack,
            [session.barrackPath]: { ...layout, slots: newSlots },
          };
          localStorage.setItem("cc-terminal-split-layouts", JSON.stringify(nextLayouts));
        }
      }

      return {
        sessions: next,
        splitLayoutPerBarrack: nextLayouts,
        activeTerminalPerBarrack: {
          ...s.activeTerminalPerBarrack,
          [session.barrackPath]: session.id,
        },
      };
    }),

  removeSession: (id) =>
    set((s) => {
      clearBuffer(id);
      const removed = s.sessions.find((t) => t.id === id);
      const remaining = s.sessions.filter((t) => t.id !== id);
      persistSessions(remaining);

      const newActive = { ...s.activeTerminalPerBarrack };
      let nextLayouts = s.splitLayoutPerBarrack;
      if (removed) {
        const bp = removed.barrackPath;
        if (newActive[bp] === id) {
          const barrackSessions = remaining.filter((t) => t.barrackPath === bp);
          newActive[bp] = barrackSessions[barrackSessions.length - 1]?.id ?? "";
          if (!newActive[bp]) delete newActive[bp];
        }

        // Clean up slot referencing removed session
        const layout = s.splitLayoutPerBarrack[bp];
        if (layout) {
          const slotIdx = layout.slots.indexOf(id);
          if (slotIdx !== -1) {
            const newSlots = [...layout.slots];
            newSlots[slotIdx] = null;
            nextLayouts = {
              ...s.splitLayoutPerBarrack,
              [bp]: { ...layout, slots: newSlots },
            };
            localStorage.setItem("cc-terminal-split-layouts", JSON.stringify(nextLayouts));
          }
        }
      }

      return {
        sessions: remaining,
        activeTerminalPerBarrack: newActive,
        splitLayoutPerBarrack: nextLayouts,
      };
    }),

  setActiveTerminal: (barrackPath, id) =>
    set((s) => ({
      activeTerminalPerBarrack: { ...s.activeTerminalPerBarrack, [barrackPath]: id },
    })),

  setPtyId: (sessionId, ptyId) =>
    set((s) => {
      const next = s.sessions.map((t) =>
        t.id === sessionId ? { ...t, ptyId } : t
      );
      persistSessions(next);
      return { sessions: next };
    }),

  setPanelWidth: (barrackPath, w) => {
    const next = { ...get().panelWidthPerBarrack, [barrackPath]: w };
    localStorage.setItem("cc-terminal-panel-widths", JSON.stringify(next));
    set({ panelWidthPerBarrack: next });
  },

  setSplitLayout: (barrackPath, layout) => {
    const next = { ...get().splitLayoutPerBarrack, [barrackPath]: layout };
    localStorage.setItem("cc-terminal-split-layouts", JSON.stringify(next));
    set({ splitLayoutPerBarrack: next });
  },

  setSlotTerminal: (barrackPath, slotIndex, sessionId) => {
    const current = get().splitLayoutPerBarrack[barrackPath];
    if (!current) return;
    const newSlots = [...current.slots];
    // Clear session from any other slot first (prevent duplicate assignment)
    if (sessionId) {
      const existingIdx = newSlots.indexOf(sessionId);
      if (existingIdx !== -1 && existingIdx !== slotIndex) {
        newSlots[existingIdx] = null;
      }
    }
    newSlots[slotIndex] = sessionId;
    const next = {
      ...get().splitLayoutPerBarrack,
      [barrackPath]: { ...current, slots: newSlots },
    };
    localStorage.setItem("cc-terminal-split-layouts", JSON.stringify(next));
    set({ splitLayoutPerBarrack: next });
  },

  setIsResizing: (v) => set({ isResizing: v }),

  updateSettings: (partial) => {
    const next = { ...get().settings, ...partial };
    localStorage.setItem("cc-terminal-settings", JSON.stringify(next));
    set({ settings: next });
  },

  addQuickCommand: (cmd) => {
    const next = [...get().quickCommands.filter((c) => c.id !== cmd.id), cmd];
    localStorage.setItem("cc-quick-commands", JSON.stringify(next));
    set({ quickCommands: next });
  },

  removeQuickCommand: (id) => {
    const next = get().quickCommands.filter((c) => c.id !== id);
    localStorage.setItem("cc-quick-commands", JSON.stringify(next));
    set({ quickCommands: next });
  },

  markExited: (id) =>
    set((s) => {
      const next = s.sessions.map((t) =>
        t.id === id ? { ...t, exited: true } : t
      );
      persistSessions(next);
      return { sessions: next };
    }),

  reconnectSessions: (survivingPtyIds) => {
    const persisted = loadPersistedSessions();
    const toReconnect = persisted.filter(
      (s) => s.ptyId && survivingPtyIds.has(s.ptyId)
    );
    if (toReconnect.length === 0) return;

    // Build activeTerminalPerBarrack from reconnected sessions
    const active: Record<string, string> = {};
    for (const s of toReconnect) {
      active[s.barrackPath] = s.id;
    }

    set({ sessions: toReconnect, activeTerminalPerBarrack: active });
    persistSessions(toReconnect);
  },
}));

// Selector: get sessions for a specific barrack
export function getSessionsForBarrack(barrackPath: string): TerminalSession[] {
  return useTerminalStore.getState().sessions.filter((s) => s.barrackPath === barrackPath);
}

// Selector: get active terminal ID for a barrack
export function getActiveTerminalId(barrackPath: string): string | null {
  return useTerminalStore.getState().activeTerminalPerBarrack[barrackPath] ?? null;
}

// Selector: get panel width for a barrack
export function getPanelWidth(barrackPath: string): number {
  return useTerminalStore.getState().panelWidthPerBarrack[barrackPath] ?? DEFAULT_PANEL_WIDTH;
}
