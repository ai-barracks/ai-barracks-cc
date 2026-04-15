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

function loadPanelWidth(): number {
  const saved = localStorage.getItem("cc-terminal-width");
  return saved ? Number(saved) || 480 : 480;
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
  // Strip ANSI escape codes for clean export
  return buf.join("").replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

export function clearBuffer(sessionId: string) {
  outputBuffers.delete(sessionId);
}

interface TerminalState {
  sessions: TerminalSession[];
  activeTerminalId: string | null;
  panelVisible: boolean;
  panelWidth: number;
  settings: TerminalSettings;
  quickCommands: QuickCommand[];
  isResizing: boolean;

  addSession: (session: TerminalSession) => void;
  removeSession: (id: string) => void;
  setActiveTerminal: (id: string) => void;
  togglePanel: () => void;
  showPanel: () => void;
  hidePanel: () => void;
  setPanelWidth: (w: number) => void;
  setIsResizing: (v: boolean) => void;
  updateSettings: (partial: Partial<TerminalSettings>) => void;
  addQuickCommand: (cmd: QuickCommand) => void;
  removeQuickCommand: (id: string) => void;
}

export const useTerminalStore = create<TerminalState>((set, get) => ({
  sessions: [],
  activeTerminalId: null,
  panelVisible: false,
  panelWidth: loadPanelWidth(),
  settings: loadSettings(),
  quickCommands: loadQuickCommands(),
  isResizing: false,

  addSession: (session) =>
    set((s) => ({
      sessions: [...s.sessions, session],
      activeTerminalId: session.id,
      panelVisible: true,
    })),

  removeSession: (id) =>
    set((s) => {
      clearBuffer(id);
      const remaining = s.sessions.filter((t) => t.id !== id);
      const nextActive =
        s.activeTerminalId === id
          ? remaining[remaining.length - 1]?.id ?? null
          : s.activeTerminalId;
      return {
        sessions: remaining,
        activeTerminalId: nextActive,
        panelVisible: remaining.length > 0 ? s.panelVisible : false,
      };
    }),

  setActiveTerminal: (id) => set({ activeTerminalId: id }),

  togglePanel: () => set((s) => ({ panelVisible: !s.panelVisible })),
  showPanel: () => set({ panelVisible: true }),
  hidePanel: () => set({ panelVisible: false }),

  setPanelWidth: (w) => {
    localStorage.setItem("cc-terminal-width", String(w));
    set({ panelWidth: w });
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
