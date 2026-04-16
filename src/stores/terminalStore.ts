import { create } from "zustand";
import type { TerminalSession, TerminalSettings, QuickCommand } from "../types";

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

function loadQuickCommands(): QuickCommand[] {
  const saved = localStorage.getItem("cc-quick-commands");
  if (!saved) return [];
  try {
    return JSON.parse(saved);
  } catch {
    return [];
  }
}

// TODO: Re-enable after Phase 2 reconnection is wired up
// function loadPersistedSessions(): TerminalSession[] {
//   const saved = localStorage.getItem("cc-terminal-sessions");
//   if (!saved) return [];
//   try { return JSON.parse(saved); } catch { return []; }
// }

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
  settings: TerminalSettings;
  quickCommands: QuickCommand[];
  isResizing: boolean;

  addSession: (session: TerminalSession) => void;
  removeSession: (id: string) => void;
  setActiveTerminal: (barrackPath: string, id: string) => void;
  setPanelWidth: (barrackPath: string, w: number) => void;
  setIsResizing: (v: boolean) => void;
  updateSettings: (partial: Partial<TerminalSettings>) => void;
  addQuickCommand: (cmd: QuickCommand) => void;
  removeQuickCommand: (id: string) => void;
}

export const useTerminalStore = create<TerminalState>((set, get) => ({
  // TODO: Enable after Phase 2 reconnection is wired up in App.tsx
  // Sessions are persisted but NOT auto-loaded — reconnection flow must validate PTYs first
  sessions: [],
  activeTerminalPerBarrack: {},
  panelWidthPerBarrack: loadPanelWidths(),
  settings: loadSettings(),
  quickCommands: loadQuickCommands(),
  isResizing: false,

  addSession: (session) =>
    set((s) => {
      const next = [...s.sessions, session];
      persistSessions(next);
      return {
        sessions: next,
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
      if (removed) {
        const bp = removed.barrackPath;
        if (newActive[bp] === id) {
          const barrackSessions = remaining.filter((t) => t.barrackPath === bp);
          newActive[bp] = barrackSessions[barrackSessions.length - 1]?.id ?? "";
          if (!newActive[bp]) delete newActive[bp];
        }
      }

      return {
        sessions: remaining,
        activeTerminalPerBarrack: newActive,
      };
    }),

  setActiveTerminal: (barrackPath, id) =>
    set((s) => ({
      activeTerminalPerBarrack: { ...s.activeTerminalPerBarrack, [barrackPath]: id },
    })),

  setPanelWidth: (barrackPath, w) => {
    const next = { ...get().panelWidthPerBarrack, [barrackPath]: w };
    localStorage.setItem("cc-terminal-panel-widths", JSON.stringify(next));
    set({ panelWidthPerBarrack: next });
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
