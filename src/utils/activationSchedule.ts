export interface ActivationConfig {
  enabled: boolean;
  claude: boolean;
  codex: boolean;
}
export interface ActivationRun {
  provider: "claude" | "codex";
  slot: string;
  status: string;
  detail: string;
}
export interface ActivationView {
  config: ActivationConfig;
  available: boolean;
  error: string | null;
  next_slot: string | null;
  history: ActivationRun[];
}
export const DEFAULT_ACTIVATION: ActivationConfig = { enabled: false, claude: true, codex: true };
export function hasSelectedCli(config: ActivationConfig): boolean {
  return config.claude || config.codex;
}
export function formatKstSlot(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Unknown";
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Seoul", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).format(date) + " KST";
}
