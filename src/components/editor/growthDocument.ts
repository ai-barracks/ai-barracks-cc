import { detectEol, splitLinesPreserveEndings } from "./documentPatch";

export interface DecisionRow {
  event: string;
  location: string;
  example: string;
}

export interface GrowthData {
  decision_table: DecisionRow[];
  not_growth_worthy: string[];
}

export interface GrowthDocument {
  readonly raw: string;
  readonly data: GrowthData;
}

export type GrowthField = "decision_table" | "not_growth_worthy";

export type GrowthPatchReason =
  | "header-not-found"
  | "multiple-headers"
  | "separator-not-found"
  | "malformed-row"
  | "anchor-not-found"
  | "multiple-anchors"
  | "multiple-bullet-runs";

export interface GrowthPatchFailure {
  readonly field: GrowthField;
  readonly reason: GrowthPatchReason;
}

export type GrowthPatchResult =
  | { readonly ok: true; readonly raw: string }
  | { readonly ok: false; readonly failure: GrowthPatchFailure };

export function parseGrowthDocument(raw: string): GrowthDocument {
  return { raw, data: parseGrowthData(raw) };
}

export function patchGrowthDocument(
  raw: string,
  next: GrowthData
): GrowthPatchResult {
  const prev = parseGrowthData(raw);
  let current = raw;

  if (!decisionRowsEqual(prev.decision_table, next.decision_table)) {
    const r = patchDecisionTable(current, next.decision_table);
    if (!r.ok) return r;
    current = r.raw;
  }

  if (!stringArraysEqual(prev.not_growth_worthy, next.not_growth_worthy)) {
    const r = patchNotGrowthList(
      current,
      prev.not_growth_worthy,
      next.not_growth_worthy
    );
    if (!r.ok) return r;
    current = r.raw;
  }

  return { ok: true, raw: current };
}

function parseGrowthData(raw: string): GrowthData {
  const data: GrowthData = { decision_table: [], not_growth_worthy: [] };
  let inTable = false;
  let inNotGrowth = false;
  const fence = createFenceState();

  for (const line of splitLinesPreserveEndings(raw)) {
    const content = stripEol(line);
    if (fence.consume(content)) continue;
    if (fence.inside()) continue;
    const trimmed = content.trim();

    if (trimmed.startsWith("|") && trimmed.includes("세션 중 이벤트")) {
      inTable = true;
      inNotGrowth = false;
      continue;
    }
    if (inTable && trimmed.startsWith("|") && trimmed.includes("---")) continue;
    if (inTable && trimmed.startsWith("|")) {
      const cols = trimmed.split("|").filter(Boolean);
      if (cols.length >= 3) {
        data.decision_table.push({
          event: cols[0].trim(),
          location: cols[1].trim(),
          example: cols[2].trim(),
        });
      }
      continue;
    }
    if (inTable && !trimmed.startsWith("|") && trimmed) {
      inTable = false;
    }

    if (
      trimmed.startsWith("**NOT growth-worthy**") ||
      trimmed.includes("기록하지 않을 것")
    ) {
      inNotGrowth = true;
      inTable = false;
      continue;
    }
    if (inNotGrowth && trimmed.startsWith("- ")) {
      data.not_growth_worthy.push(trimmed.slice(2));
      continue;
    }
    if (inNotGrowth && trimmed.startsWith("##")) {
      inNotGrowth = false;
    }
  }
  return data;
}

function patchDecisionTable(
  raw: string,
  newRows: readonly DecisionRow[]
): GrowthPatchResult {
  const lines = splitLinesPreserveEndings(raw);

  const headerIndices: number[] = [];
  const fence = createFenceState();
  for (let i = 0; i < lines.length; i++) {
    const content = stripEol(lines[i]);
    if (fence.consume(content)) continue;
    if (fence.inside()) continue;
    const t = content.trim();
    if (t.startsWith("|") && t.includes("세션 중 이벤트")) headerIndices.push(i);
  }
  if (headerIndices.length === 0) return tableFail("header-not-found");
  if (headerIndices.length > 1) return tableFail("multiple-headers");
  const headerIdx = headerIndices[0];

  let sepIdx = -1;
  for (let i = headerIdx + 1; i < lines.length; i++) {
    const t = stripEol(lines[i]).trim();
    if (!t.startsWith("|")) continue;
    if (!t.includes("---")) return tableFail("separator-not-found");
    sepIdx = i;
    break;
  }
  if (sepIdx === -1) return tableFail("separator-not-found");

  const dataStart = sepIdx + 1;
  let dataEnd = dataStart;
  while (
    dataEnd < lines.length &&
    stripEol(lines[dataEnd]).trim().startsWith("|")
  ) {
    dataEnd++;
  }

  for (let i = dataStart; i < dataEnd; i++) {
    const t = stripEol(lines[i]).trim();
    const cols = t.split("|").filter(Boolean);
    if (cols.length < 3) return tableFail("malformed-row");
  }

  let perLineEol = "";
  for (let i = dataStart; i < dataEnd; i++) {
    const e = lineEol(lines[i]);
    if (e) {
      perLineEol = e;
      break;
    }
  }
  if (!perLineEol) perLineEol = lineEol(lines[sepIdx]);
  if (!perLineEol) perLineEol = detectEol(raw);

  const hadDataRows = dataEnd > dataStart;
  const lastOriginalHasEol = hadDataRows
    ? lineEol(lines[dataEnd - 1]) !== ""
    : true;

  const newRowLines = newRows.map((row, k) => {
    const isLast = k === newRows.length - 1;
    const eol =
      isLast && hadDataRows && !lastOriginalHasEol ? "" : perLineEol;
    return `| ${row.event} | ${row.location} | ${row.example} |${eol}`;
  });

  let head = lines.slice(0, dataStart);
  if (!hadDataRows && newRows.length > 0 && lineEol(lines[sepIdx]) === "") {
    head = [...lines.slice(0, sepIdx), lines[sepIdx] + perLineEol];
  }
  const tail = lines.slice(dataEnd);

  return { ok: true, raw: [...head, ...newRowLines, ...tail].join("") };
}

function patchNotGrowthList(
  raw: string,
  oldList: readonly string[],
  newList: readonly string[]
): GrowthPatchResult {
  const lines = splitLinesPreserveEndings(raw);

  const anchorIndices: number[] = [];
  const anchorFence = createFenceState();
  for (let i = 0; i < lines.length; i++) {
    const content = stripEol(lines[i]);
    if (anchorFence.consume(content)) continue;
    if (anchorFence.inside()) continue;
    const t = content.trim();
    if (
      t.startsWith("**NOT growth-worthy**") ||
      t.includes("기록하지 않을 것")
    ) {
      anchorIndices.push(i);
    }
  }
  if (anchorIndices.length === 0) return notFail("anchor-not-found");
  if (anchorIndices.length > 1) return notFail("multiple-anchors");
  const anchorIdx = anchorIndices[0];

  const fence = createFenceState();
  const runs: { start: number; end: number }[] = [];
  let curStart = -1;
  let i = anchorIdx + 1;
  while (i < lines.length) {
    const content = stripEol(lines[i]);
    const isFenceMarker = fence.consume(content);
    const inFence = fence.inside();
    if (isFenceMarker || inFence) {
      if (curStart !== -1) {
        runs.push({ start: curStart, end: i });
        curStart = -1;
      }
      i++;
      continue;
    }
    const trimmed = content.trim();
    if (/^#{1,6}(?:\s|$)/.test(trimmed)) {
      if (curStart !== -1) {
        runs.push({ start: curStart, end: i });
        curStart = -1;
      }
      break;
    }
    if (isBulletLine(content)) {
      if (curStart === -1) curStart = i;
    } else if (curStart !== -1) {
      runs.push({ start: curStart, end: i });
      curStart = -1;
    }
    i++;
  }
  if (curStart !== -1) runs.push({ start: curStart, end: i });

  if (runs.length > 1) return notFail("multiple-bullet-runs");

  if (runs.length === 1) {
    const run = runs[0];
    let perLineEol = "";
    for (let k = run.start; k < run.end; k++) {
      const e = lineEol(lines[k]);
      if (e) {
        perLineEol = e;
        break;
      }
    }
    if (!perLineEol) perLineEol = detectEol(raw);

    const lastOriginalHasEol = lineEol(lines[run.end - 1]) !== "";

    const newBulletLines = newList.map((b, k) => {
      const isLast = k === newList.length - 1;
      const eol = isLast && !lastOriginalHasEol ? "" : perLineEol;
      return `- ${b}${eol}`;
    });

    const out = [
      ...lines.slice(0, run.start),
      ...newBulletLines,
      ...lines.slice(run.end),
    ];
    return { ok: true, raw: out.join("") };
  }

  if (oldList.length !== 0) return notFail("multiple-bullet-runs");
  if (newList.length === 0) return { ok: true, raw };

  const eol = lineEol(lines[anchorIdx]) || detectEol(raw);
  let head = lines.slice(0, anchorIdx + 1);
  if (lineEol(lines[anchorIdx]) === "") {
    head = [...lines.slice(0, anchorIdx), lines[anchorIdx] + eol];
  }
  const newBulletLines = newList.map((b) => `- ${b}${eol}`);
  const tail = lines.slice(anchorIdx + 1);
  return { ok: true, raw: [...head, ...newBulletLines, ...tail].join("") };
}

function tableFail(reason: GrowthPatchReason): GrowthPatchResult {
  return { ok: false, failure: { field: "decision_table", reason } };
}

function notFail(reason: GrowthPatchReason): GrowthPatchResult {
  return { ok: false, failure: { field: "not_growth_worthy", reason } };
}

function decisionRowsEqual(
  a: readonly DecisionRow[],
  b: readonly DecisionRow[]
): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (
      a[i].event !== b[i].event ||
      a[i].location !== b[i].location ||
      a[i].example !== b[i].example
    )
      return false;
  }
  return true;
}

function stringArraysEqual(
  a: readonly string[],
  b: readonly string[]
): boolean {
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

function isBulletLine(content: string): boolean {
  return content.trim().startsWith("- ");
}

function createFenceState() {
  let inFence = false;
  let fenceChar: "`" | "~" | null = null;
  let fenceLen = 0;
  return {
    consume(content: string): boolean {
      const m = /^ {0,3}(`{3,}|~{3,})/.exec(content);
      if (!m) return false;
      const ch = m[1][0] as "`" | "~";
      const len = m[1].length;
      if (!inFence) {
        inFence = true;
        fenceChar = ch;
        fenceLen = len;
      } else if (ch === fenceChar && len >= fenceLen) {
        inFence = false;
        fenceChar = null;
        fenceLen = 0;
      }
      return true;
    },
    inside(): boolean {
      return inFence;
    },
  };
}
