import { afterEach, describe, expect, it, vi } from "vitest";
import { readProviderProfile, saveProviderProfile } from "./providerProfile";
afterEach(() => vi.unstubAllGlobals());
describe("provider profiles", () => {
  it("defaults to runtime and tolerates unavailable storage", () => {
    vi.stubGlobal("localStorage", { getItem: () => { throw new Error(); } });
    expect(readProviderProfile("codex")).toEqual({ model: "", effort: "" });
  });
  it("persists explicit profile without pinning defaults", () => {
    const values = new Map<string, string>();
    vi.stubGlobal("localStorage", { getItem: (key: string) => values.get(key), setItem: (key: string, value: string) => values.set(key, value) });
    saveProviderProfile("codex", { model: "future-model", effort: "high" });
    expect(readProviderProfile("codex")).toEqual({ model: "future-model", effort: "high" });
    expect(readProviderProfile("claude")).toEqual({ model: "", effort: "" });
  });
  it("rejects malformed controls and unsupported efforts", () => {
    for (const value of [{ model: "bad\n", effort: "high" }, { model: "ok", effort: "bad" }, { model: 42 }]) {
      vi.stubGlobal("localStorage", { getItem: () => JSON.stringify(value) });
      expect(readProviderProfile("codex")).toEqual({ model: "", effort: "" });
    }
  });
});
