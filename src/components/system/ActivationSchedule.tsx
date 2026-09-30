import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { DEFAULT_ACTIVATION, formatKstSlot, hasSelectedCli } from "../../utils/activationSchedule";
import type { ActivationConfig, ActivationView } from "../../utils/activationSchedule";

export function ActivationSchedule() {
  const [view, setView] = useState<ActivationView | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const request = useRef(0);
  const busy = useRef(false);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    const refresh = async () => {
      if (busy.current) return;
      const id = ++request.current;
      try {
        const result = await invoke<ActivationView>("get_activation_schedule");
        if (mounted.current && id === request.current) { setView(result); setError(null); }
      } catch (e) {
        if (mounted.current && id === request.current) setError(String(e));
      }
    };
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    return () => { mounted.current = false; ++request.current; clearInterval(timer); };
  }, []);

  const config = view?.config ?? DEFAULT_ACTIVATION;
  const disabled = !view || !view.available || saving;
  const save = async (updated: ActivationConfig) => {
    busy.current = true; ++request.current; setSaving(true); setError(null); setConfirming(false);
    try {
      const result = await invoke<ActivationView>("save_activation_schedule", { config: updated });
      if (mounted.current) setView(result);
    } catch (e) {
      if (mounted.current) setError(String(e));
      // OFF may have cancelled execution even when persistence failed; refresh the actual state.
      try { const result = await invoke<ActivationView>("get_activation_schedule"); if (mounted.current) setView(result); } catch { /* Keep last known state; error remains visible. */ }
    } finally { busy.current = false; if (mounted.current) setSaving(false); }
  };
  return (
    <section className="mb-8 border border-cc-border rounded-lg p-4 bg-cc-panel/40" aria-label="Scheduled activation">
      <div className="flex items-center justify-between gap-3 mb-2">
        <h2 className="text-[15px] font-semibold">Scheduled activation</h2>
        <button type="button" role="switch" aria-checked={config.enabled} aria-label="Scheduled activation on/off"
          disabled={saving || !view || (!view.available && !config.enabled)}
          onClick={() => config.enabled ? void save({ ...config, enabled: false }) : setConfirming(true)}
          className={`text-[12px] px-3 py-1 rounded-md border disabled:opacity-40 ${config.enabled ? "border-cc-success text-cc-success" : "border-cc-border text-cc-text-dim"}`}>
          {saving ? "Saving…" : config.enabled ? "ON" : "OFF"}
        </button>
      </div>
      <p className="text-[13px] text-cc-text-dim">06:00 · 11:00 · 16:00 · 21:00 — Asia/Seoul (KST)</p>
      <div className="flex gap-5 my-3 text-[13px]">
        {(["claude", "codex"] as const).map((provider) => (
          <label key={provider} className="flex items-center gap-2">
            <input type="checkbox" checked={config[provider]} disabled={disabled}
              onChange={(e) => void save({ ...config, [provider]: e.target.checked })} className="accent-cc-accent" />
            {provider === "claude" ? "Claude Code" : "Codex"}
          </label>
        ))}
      </div>
      <p className="text-[12px] text-cc-text-dim leading-relaxed">
        One “OK” request per selected CLI per slot. Subscription login required; no API-key fallback.
        Requests consume usage and do not guarantee a quota reset. Extra usage/credits may still be billed by your plan.
        Uses the isolated CLI default model, not a pinned model or your project settings.
      </p>
      <p className="text-[12px] text-cc-text-dim mt-2 leading-relaxed">
        Runs only while CommandCenter and your Mac are awake (hiding to tray is OK).
        No wake-from-sleep, missed-slot catch-up or automatic retries. Turning ON starts at the next future slot.
        OFF stops pending work; it cannot undo a request already sent.
      </p>
      {confirming && (
        <div className="mt-3 p-3 border border-cc-warning/40 rounded-md text-[12px]" role="alert">
          <p>Enable actual model requests at these four daily slots? Each CLI invocation can include provider-internal retries.</p>
          <div className="flex gap-3 mt-2">
            <button type="button" disabled={disabled || !hasSelectedCli(config)} onClick={() => void save({ ...config, enabled: true })}
              className="px-3 py-1.5 rounded bg-cc-accent text-white disabled:opacity-40">Enable requests</button>
            <button type="button" onClick={() => setConfirming(false)} className="text-cc-text-dim">Cancel</button>
          </div>
          {!hasSelectedCli(config) && <p className="mt-2 text-cc-warning">Select at least one CLI.</p>}
        </div>
      )}
      {(error || view?.error) && <p role="alert" className="mt-3 text-[12px] text-cc-danger">{error || view?.error}<br />저장 실패 시 현재 앱의 OFF 요청은 취소되지만 재시작 전 저장소 오류를 해결하고 OFF 저장을 확인하세요.</p>}
      <p className="mt-3 text-[12px] text-cc-text-dim">
        {!view ? "Loading scheduler…" : config.enabled && view.next_slot ? `Next: ${formatKstSlot(view.next_slot)}` : "Disabled — no requests scheduled"}
      </p>
      {view && view.history.length > 0 && (
        <details className="mt-3 text-[12px]">
          <summary className="cursor-pointer text-cc-text-dim">Recent activations ({view.history.length})</summary>
          <ul className="mt-2 space-y-2 max-h-48 overflow-y-auto">
            {view.history.map((run) => (
              <li key={`${run.provider}-${run.slot}`} className="border-t border-cc-border pt-2">
                <span className="font-medium">{run.provider} · {formatKstSlot(run.slot)} · {run.status}</span>
                <p className="text-cc-text-dim">{run.detail}</p>
              </li>
            ))}
          </ul>
        </details>
      )}
    </section>
  );
}
