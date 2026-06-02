import { invoke } from "@tauri-apps/api/core";

let cachedAibPath: string | null = null;

export async function getAibPath(): Promise<string> {
  if (cachedAibPath !== null) return cachedAibPath;
  cachedAibPath = await invoke<string>("get_aib_path");
  return cachedAibPath;
}

export function shellQuote(value: string): string {
  if (value.length === 0) return "''";
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

export function shellJoin(args: readonly string[]): string {
  return args.map(shellQuote).join(" ");
}

export function aibCommand(aibPath: string, args: readonly string[]): string {
  return shellJoin([aibPath, ...args]);
}

export function printfLine(value: string): string {
  return `printf '%s\\n' ${shellQuote(value)}`;
}
