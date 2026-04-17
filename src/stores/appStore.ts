import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { getVersion } from "@tauri-apps/api/app";
import type { BarrackInfo, TabType } from "../types";

type Theme = "dark" | "light";

interface AppState {
  barracks: BarrackInfo[];
  selectedBarrack: BarrackInfo | null;
  activeTab: TabType;
  lastTabPerBarrack: Record<string, TabType>;
  cliVersion: string;
  appVersion: string;
  loading: boolean;
  error: string | null;
  theme: Theme;

  fetchBarracks: () => Promise<void>;
  fetchCliVersion: () => Promise<void>;
  fetchAppVersion: () => Promise<void>;
  selectBarrack: (barrack: BarrackInfo) => void;
  setActiveTab: (tab: TabType) => void;
  pendingConfigFile: string | null;
  showSystemView: () => void;
  openConfigFile: (filename: string) => void;
  clearPendingConfigFile: () => void;
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
  lastTabPerBarrack: {},
  cliVersion: "",
  appVersion: "",
  loading: false,
  error: null,
  theme: getInitialTheme(),
  pendingConfigFile: null,

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

  fetchAppVersion: async () => {
    try {
      const version = await getVersion();
      set({ appVersion: version });
    } catch {
      set({ appVersion: "" });
    }
  },

  selectBarrack: (barrack) => {
    const lastTab = get().lastTabPerBarrack[barrack.path] ?? "overview";
    set({ selectedBarrack: barrack, activeTab: lastTab, pendingConfigFile: null });
  },
  showSystemView: () => set({ selectedBarrack: null, pendingConfigFile: null }),
  openConfigFile: (filename: string) => set({ activeTab: "files", pendingConfigFile: filename }),
  clearPendingConfigFile: () => set({ pendingConfigFile: null }),
  setActiveTab: (tab) => {
    const bp = get().selectedBarrack?.path;
    set({
      activeTab: tab,
      lastTabPerBarrack: bp
        ? { ...get().lastTabPerBarrack, [bp]: tab }
        : get().lastTabPerBarrack,
    });
  },
  clearError: () => set({ error: null }),
  toggleTheme: () => {
    const next = get().theme === "dark" ? "light" : "dark";
    applyTheme(next);
    set({ theme: next });
  },
}));
