import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { readProviderProfile, saveProviderProfile } from "../../utils/providerProfile";

type Model = { model: string; name: string; efforts: string[]; is_default: boolean };
type Info = { models: Model[]; source: string };
function Provider({ client }: { client: "claude" | "codex" }) {
  const [profile, setProfile] = useState(() => readProviderProfile(client));
  const [info, setInfo] = useState<Info | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const selected = info?.models.find(m => m.model === profile.model);
  const efforts = selected?.efforts ?? (client === "codex" ? ["none", "minimal", "low", "medium", "high", "xhigh"] : ["low", "medium", "high", "max"]);
  const load = async () => {
    setBusy(true); setError("");
    try { setInfo(await invoke<Info>("get_provider_models", { client })); }
    catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  };
  return <div className="p-3 border border-cc-border rounded-md space-y-2">
    <div className="flex justify-between items-center"><strong className="text-sm">{client === "codex" ? "Codex" : "Claude Code"}</strong><button onClick={load} disabled={busy} className="text-xs text-cc-accent disabled:opacity-50">{busy ? "조회 중…" : "모델 목록 조회"}</button></div>
    <label className="block text-xs">Model (빈 값 = CLI runtime default)
      <input aria-label={`${client} model`} list={`${client}-models`} value={profile.model} maxLength={200} onChange={e => { setProfile({ model: e.target.value, effort: "" }); setSaved(false); }} className="mt-1 w-full bg-cc-bg border border-cc-border rounded p-2" placeholder="runtime default / custom model ID" />
      <datalist id={`${client}-models`}>{info?.models.map(m => <option key={m.model} value={m.model}>{m.name}{m.is_default ? " (default)" : ""}</option>)}</datalist>
    </label>
    <label className="block text-xs">Reasoning effort
      <select aria-label={`${client} effort`} value={profile.effort} onChange={e => { setProfile({ ...profile, effort: e.target.value }); setSaved(false); }} className="ml-2 bg-cc-bg border border-cc-border rounded p-1"><option value="">runtime default</option>{efforts.map(e => <option key={e}>{e}</option>)}</select>
    </label>
    <button onClick={() => { try { saveProviderProfile(client, profile); setSaved(true); } catch { setError("Profile 저장 실패"); } }} className="text-xs px-3 py-1 border border-cc-border rounded">새 세션에 적용</button>{saved && <span className="text-xs ml-2 text-cc-text-dim">저장됨</span>}
    {info && <p className="text-xs text-cc-text-dim">{info.source}</p>}
    {error && <p role="alert" className="text-xs text-red-400">{error}</p>}
  </div>;
}
export function ProviderModels() {
  return <section className="mb-5 p-4 bg-cc-panel border border-cc-border rounded-lg">
    <h2 className="font-semibold mb-2">Provider / Model profiles</h2>
    <p className="text-xs text-cc-text-dim mb-3">조회는 모델 요청을 보내지 않습니다. Codex는 설치 CLI·계정이 광고하는 목록, Claude는 문서상 alias입니다. 지원 여부는 CLI가 최종 검증합니다. Sessions·Command Palette의 새 세션에만 적용하며 기존 세션과 예약 활성화에는 적용하지 않습니다.</p>
    <div className="grid gap-3 md:grid-cols-2"><Provider client="codex" /><Provider client="claude" /></div>
  </section>;
}
