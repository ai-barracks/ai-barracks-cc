export type ProviderProfile = { model: string; effort: string };
const EMPTY = { model: "", effort: "" };
export function readProviderProfile(client: string): ProviderProfile {
  try {
    const value = JSON.parse(localStorage.getItem(`aib-profile-${client}`) || "null");
    if (typeof value?.model !== "string" || typeof value?.effort !== "string" || value.model.length > 200 || /[\x00-\x1f]/.test(value.model)) return { ...EMPTY };
    const efforts = client === "codex" ? ["", "none", "minimal", "low", "medium", "high", "xhigh"] : ["", "low", "medium", "high", "max"];
    return efforts.includes(value.effort) ? value : { ...EMPTY };
  } catch { return { ...EMPTY }; }
}
export function saveProviderProfile(client: string, profile: ProviderProfile) {
  localStorage.setItem(`aib-profile-${client}`, JSON.stringify(profile));
}
