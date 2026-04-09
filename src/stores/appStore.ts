import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import type { BarrackInfo, TabType } from "../types";

type Theme = "dark" | "light";

interface AppState {
  barracks: BarrackInfo[];
  selectedBarrack: BarrackInfo | null;
  activeTab: TabType;
  cliVersion: string;
  loading: boolean;
  error: string | null;
  theme: Theme;

  fetchBarracks: () => Promise<void>;
  fetchCliVersion: () => Promise<void>;
  selectBarrack: (barrack: BarrackInfo) => void;
  setActiveTab: (tab: TabType) => void;
  clearError: () => void;
  toggleTheme: () => void;
}

function getInitialTheme(): Theme {
  const saved = localStorage.getItem("cc-theme") as Theme | null;
  return saved ?? "dark";
}

function applyTheme(theme: Theme) {
  document.documentElement.setAttribute("data-theme", theme);
  localStorage.setItem("cc-theme", theme);
}

export const useAppStore = create<AppState>((set, get) => ({
  barracks: [],
  selectedBarrack: null,
  activeTab: "overview",
  cliVersion: "",
  loading: false,
  error: null,
  theme: getInitialTheme(),

  fetchBarracks: async () => {
    set({ loading: true, error: null });
    try {
      const barracks = await invoke<BarrackInfo[]>("get_barracks");
      const current = get().selectedBarrack;
      const updated = current
        ? barracks.find((b) => b.path === current.path) ?? null
        : null;
      set({ barracks, selectedBarrack: updated, loading: false });
    } catch (e) {
      set({ error: String(e), loading: false });
    }
  },

  fetchCliVersion: async () => {
    try {
      const version = await invoke<string>("get_cli_version");
      set({ cliVersion: version });
    } catch {
      set({ cliVersion: "unknown" });
    }
  },

  selectBarrack: (barrack) => set({ selectedBarrack: barrack, activeTab: "overview" }),
  setActiveTab: (tab) => set({ activeTab: tab }),
  clearError: () => set({ error: null }),
  toggleTheme: () => {
    const next = get().theme === "dark" ? "light" : "dark";
    applyTheme(next);
    set({ theme: next });
  },
}));
