import { detectEol, splitLinesPreserveEndings } from "./documentPatch";

export interface AgentConfig {
  name: string;
  version: string;
  description: string;
  primary_model: string;
  fallback_models: string[];
  aib_version: string;
}

export interface AgentYamlDocument {
  readonly raw: string;
  readonly data: AgentConfig;
}

export type AgentYamlField =
  | "name"
  | "version"
  | "description"
  | "primary_model"
  | "fallback_models"
  | "aib_version";

export type AgentYamlPatchReason =
  | "key-not-found"
  | "multiple-keys"
  | "models-not-found"
  | "primary-not-found";

export interface AgentYamlPatchFailure {
  readonly field: AgentYamlField;
  readonly reason: AgentYamlPatchReason;
}

export type AgentYamlPatchResult =
  | { readonly ok: true; readonly raw: string }
  | { readonly ok: false; readonly failure: AgentYamlPatchFailure };

export function parseAgentYamlDocument(raw: string): AgentYamlDocument {
  return { raw, data: parseAgentConfig(raw) };
}

export function patchAgentYamlDocument(
  raw: string,
  next: AgentConfig
): AgentYamlPatchResult {
  const prev = parseAgentConfig(raw);
  let current = raw;

  for (const key of ["name", "version", "description", "aib_version"] as const) {
    if (prev[key] === next[key]) continue;
    const result = patchTopLevelScalar(current, key, next[key]);
    if (!result.ok) return { ok: false, failure: { field: key, reason: result.reason } };
    current = result.raw;
  }

  if (prev.primary_model !== next.primary_model) {
    const result = patchModelsPrimary(current, next.primary_model);
    if (!result.ok) return { ok: false, failure: { field: "primary_model", reason: result.reason } };
    current = result.raw;
  }

  if (!arraysEqual(prev.fallback_models, next.fallback_models)) {
    const result = patchModelsFallback(current, next.fallback_models);
    if (!result.ok) return { ok: false, failure: { field: "fallback_models", reason: result.reason } };
    current = result.raw;
  }

  return { ok: true, raw: current };
}

function parseAgentConfig(raw: string): AgentConfig {
  const config: AgentConfig = {
    name: "",
    version: "",
    description: "",
    primary_model: "",
    fallback_models: [],
    aib_version: "",
  };

  const lines = splitLinesPreserveEndings(raw);
  let inModels = false;
  let inFallback = false;
  for (const line of lines) {
    const content = stripEol(line);
    if (/^models\s*:/.test(content)) {
      inModels = true;
      inFallback = false;
    } else if (content.startsWith("name:")) {
      config.name = unquote(valuePart(content));
      inModels = false;
      inFallback = false;
    } else if (content.startsWith("version:")) {
      config.version = unquote(valuePart(content));
      inModels = false;
      inFallback = false;
    } else if (content.startsWith("description:")) {
      config.description = unquote(valuePart(content));
      inModels = false;
      inFallback = false;
    } else if (content.startsWith("aib_version:")) {
      config.aib_version = unquote(valuePart(content));
      inModels = false;
      inFallback = false;
    } else if (isTopLevelKey(content)) {
      inModels = false;
      inFallback = false;
    } else if (inModels && /^\s+primary:/.test(content)) {
      config.primary_model = unquote(valuePart(content));
      inFallback = false;
    } else if (inModels && /^\s+fallback:\s*(?:#.*)?$/.test(content)) {
      inFallback = true;
    } else if (inModels && inFallback && /^\s+-\s+/.test(content)) {
      config.fallback_models.push(unquote(listValuePart(content)));
    } else if (inModels && inFallback && /^\s+\S/.test(content)) {
      inFallback = false;
    }
  }
  return config;
}

function patchTopLevelScalar(
  raw: string,
  key: "name" | "version" | "description" | "aib_version",
  value: string
): { ok: true; raw: string } | { ok: false; reason: "key-not-found" | "multiple-keys" } {
  const lines = splitLinesPreserveEndings(raw);
  const matches: number[] = [];
  const re = new RegExp(`^${escapeRegExp(key)}\\s*:`);
  for (let i = 0; i < lines.length; i++) {
    if (re.test(stripEol(lines[i]))) matches.push(i);
  }
  if (matches.length === 0) return { ok: false, reason: "key-not-found" };
  if (matches.length > 1) return { ok: false, reason: "multiple-keys" };
  const idx = matches[0];
  const eol = lineEol(lines[idx]);
  const nextLine = renderScalarLine(stripEol(lines[idx]), key, value) + eol;
  const nextLines = [...lines];
  nextLines[idx] = nextLine;
  return { ok: true, raw: nextLines.join("") };
}

function patchModelsPrimary(raw: string, value: string): {
  ok: true; raw: string;
} | { ok: false; reason: "models-not-found" | "primary-not-found" } {
  const block = findModelsBlock(raw);
  if (!block) return { ok: false, reason: "models-not-found" };
  const { lines, start, end } = block;
  let primaryIdx = -1;
  for (let i = start + 1; i < end; i++) {
    if (/^\s+primary\s*:/.test(stripEol(lines[i]))) {
      primaryIdx = i;
      break;
    }
  }
  if (primaryIdx === -1) return { ok: false, reason: "primary-not-found" };
  const eol = lineEol(lines[primaryIdx]);
  const old = stripEol(lines[primaryIdx]);
  const indent = old.match(/^\s*/)?.[0] ?? "  ";
  const nextLine = renderScalarLine(old, `${indent}primary`, value) + eol;
  const nextLines = [...lines];
  nextLines[primaryIdx] = nextLine;
  return { ok: true, raw: nextLines.join("") };
}

function patchModelsFallback(raw: string, values: readonly string[]): {
  ok: true; raw: string;
} | { ok: false; reason: "models-not-found" } {
  const block = findModelsBlock(raw);
  if (!block) return { ok: false, reason: "models-not-found" };
  const { lines, start, end } = block;
  let fallbackIdx = -1;
  for (let i = start + 1; i < end; i++) {
    if (/^\s+fallback\s*:/.test(stripEol(lines[i]))) {
      fallbackIdx = i;
      break;
    }
  }

  const eol = detectEol(raw);
  const nextLines = [...lines];
  if (fallbackIdx === -1) {
    if (values.length === 0) return { ok: true, raw };
    let insertAt = start + 1;
    for (let i = start + 1; i < end; i++) {
      if (/^\s+primary\s*:/.test(stripEol(lines[i]))) insertAt = i + 1;
    }
    const fallbackLines = [
      `  fallback:${eol}`,
      ...values.map((v) => `    - ${renderValueLike("", v)}${eol}`),
    ];
    nextLines.splice(insertAt, 0, ...fallbackLines);
    return { ok: true, raw: nextLines.join("") };
  }

  let listStart = fallbackIdx + 1;
  let listEnd = listStart;
  while (listEnd < end && /^\s+-\s+/.test(stripEol(lines[listEnd]))) listEnd++;
  if (values.length === 0) {
    nextLines.splice(fallbackIdx, listEnd - fallbackIdx);
    return { ok: true, raw: nextLines.join("") };
  }

  const fallbackEol = lineEol(lines[fallbackIdx]) || eol;
  const itemIndent = listStart < listEnd
    ? stripEol(lines[listStart]).match(/^\s*/)?.[0] ?? "    "
    : "    ";
  const itemEol = listStart < listEnd ? lineEol(lines[listStart]) || fallbackEol : fallbackEol;
  const replacement = [
    stripEol(lines[fallbackIdx]) + fallbackEol,
    ...values.map((v, idx) => {
      if (idx < listEnd - listStart) {
        const oldLine = lines[listStart + idx];
        return renderListItemLine(stripEol(oldLine), v) + (lineEol(oldLine) || itemEol);
      }
      return `${itemIndent}- ${renderValueLike("", v)}${itemEol}`;
    }),
  ];
  nextLines.splice(fallbackIdx, listEnd - fallbackIdx, ...replacement);
  return { ok: true, raw: nextLines.join("") };
}

function findModelsBlock(raw: string): { lines: string[]; start: number; end: number } | null {
  const lines = splitLinesPreserveEndings(raw);
  const starts: number[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (/^models\s*:/.test(stripEol(lines[i]))) starts.push(i);
  }
  if (starts.length !== 1) return null;
  const start = starts[0];
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^[A-Za-z_][A-Za-z0-9_-]*\s*:/.test(stripEol(lines[i]))) {
      end = i;
      break;
    }
  }
  return { lines, start, end };
}

function isTopLevelKey(line: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_-]*\s*:/.test(line);
}

function renderScalarLine(oldLine: string, keyText: string, value: string): string {
  const idx = oldLine.indexOf(":");
  const prefix = idx >= 0 ? oldLine.slice(0, idx + 1) : `${keyText}:`;
  const oldRest = idx >= 0 ? oldLine.slice(idx + 1) : "";
  const { valueText, comment } = splitValueAndComment(oldRest);
  const rendered = renderValueLike(valueText.trim(), value);
  return `${prefix} ${rendered}${comment}`;
}

function valuePart(line: string): string {
  const idx = line.indexOf(":");
  if (idx === -1) return "";
  return splitValueAndComment(line.slice(idx + 1)).valueText.trim();
}

function listValuePart(line: string): string {
  return splitValueAndComment(line.replace(/^\s+-\s+/, "")).valueText.trim();
}

function renderListItemLine(oldLine: string, value: string): string {
  const m = /^(\s*-\s*)(.*)$/.exec(oldLine);
  if (!m) return `    - ${renderValueLike("", value)}`;
  const { valueText, comment } = splitValueAndComment(m[2]);
  return `${m[1]}${renderValueLike(valueText.trim(), value)}${comment}`;
}

function splitValueAndComment(rest: string): { valueText: string; comment: string } {
  let quote: '"' | "'" | null = null;
  for (let i = 0; i < rest.length; i++) {
    const ch = rest[i];
    if (quote) {
      if (ch === quote && rest[i - 1] !== "\\") quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "#" && (i === 0 || /\s/.test(rest[i - 1]))) {
      return { valueText: rest.slice(0, i).trimEnd(), comment: rest.slice(i === 0 ? i : i - 1) };
    }
  }
  return { valueText: rest, comment: "" };
}

function renderValueLike(oldValue: string, value: string): string {
  if (oldValue.startsWith("'") && oldValue.endsWith("'")) {
    return `'${value.replace(/'/g, "''")}'`;
  }
  if (oldValue.startsWith('"') && oldValue.endsWith('"')) {
    return renderDoubleQuoted(value);
  }
  if (needsQuotedScalar(value)) return renderDoubleQuoted(value);
  return value;
}

function needsQuotedScalar(value: string): boolean {
  return (
    value === "" ||
    value.trim() !== value ||
    value.includes("#") ||
    /:\s/.test(value) ||
    /[\r\n]/.test(value)
  );
}

function renderDoubleQuoted(value: string): string {
  return `"${value
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\r/g, "\\r")
    .replace(/\n/g, "\\n")}"`;
}

function unquote(value: string): string {
  const trimmed = value.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return unescapeDoubleQuoted(trimmed.slice(1, -1));
  }
  if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.slice(1, -1).replace(/''/g, "'");
  }
  return trimmed;
}

function unescapeDoubleQuoted(value: string): string {
  return value.replace(/\\([\\nrt"])/g, (_, escaped: string) => {
    switch (escaped) {
      case "n":
        return "\n";
      case "r":
        return "\r";
      case "t":
        return "\t";
      default:
        return escaped;
    }
  });
}

function arraysEqual(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function stripEol(line: string): string {
  if (line.endsWith("\r\n")) return line.slice(0, -2);
  if (line.endsWith("\n")) return line.slice(0, -1);
  return line;
}

function lineEol(line: string): string {
  if (line.endsWith("\r\n")) return "\r\n";
  if (line.endsWith("\n")) return "\n";
  return "";
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
