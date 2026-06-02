import {
  detectEol,
  splitLinesPreserveEndings,
  splitMarkdownSections,
  joinMarkdownSections,
  patchBulletRunInSection,
  type MarkdownSection,
} from "./documentPatch";
import type { RulesData } from "../../types";

export type { RulesData };

export interface RulesDocument {
  readonly raw: string;
  readonly data: RulesData;
}

export type RulesField = "must_always" | "must_never" | "learned";

export type RulesPatchReason =
  | "section-not-found"
  | "multiple-sections"
  | "multiple-bullet-runs";

export interface RulesPatchFailure {
  readonly field: RulesField;
  readonly reason: RulesPatchReason;
}

export type RulesPatchResult =
  | { readonly ok: true; readonly raw: string }
  | { readonly ok: false; readonly failure: RulesPatchFailure };

const SECTION_SPECS: ReadonlyArray<{ field: RulesField; heading: string }> = [
  { field: "must_always", heading: "Must Always" },
  { field: "must_never", heading: "Must Never" },
  { field: "learned", heading: "Learned" },
];

const TEMPLATE =
  "# Rules\n\n## Must Always\n\n## Must Never\n\n## Learned\n";

export function emptyRulesTemplate(): string {
  return TEMPLATE;
}

export function parseRulesDocument(raw: string): RulesDocument {
  return { raw, data: parseRulesData(raw) };
}

export function patchRulesDocument(
  raw: string,
  next: RulesData
): RulesPatchResult {
  // Treat an empty raw as if it were the minimal template — the patch then
  // either no-ops (everything empty) or inserts bullets into the empty
  // managed sections, producing a well-formed RULES.md.
  const effectiveRaw = raw === "" ? TEMPLATE : raw;
  const prev = parseRulesData(effectiveRaw);
  let current = effectiveRaw;

  for (const spec of SECTION_SPECS) {
    const oldList = prev[spec.field];
    const newList = next[spec.field];
    if (arraysEqual(oldList, newList)) continue;
    const r = patchListSection(
      current,
      spec.field,
      spec.heading,
      oldList,
      newList
    );
    if (!r.ok) return r;
    current = r.raw;
  }

  return { ok: true, raw: current };
}

function parseRulesData(raw: string): RulesData {
  const data: RulesData = { must_always: [], must_never: [], learned: [] };
  const sections = splitMarkdownSections(raw);
  for (const section of sections) {
    if (section.level !== 2 || section.heading === null) continue;
    switch (section.heading) {
      case "Must Always":
        data.must_always = extractManagedBullets(section.raw);
        break;
      case "Must Never":
        data.must_never = extractManagedBullets(section.raw);
        break;
      case "Learned":
        data.learned = extractManagedBullets(section.raw);
        break;
      default:
        break;
    }
  }
  return data;
}

function extractManagedBullets(sectionRaw: string): string[] {
  const lines = splitLinesPreserveEndings(sectionRaw);
  const out: string[] = [];
  const fence = createFenceState();
  for (let i = 1; i < lines.length; i++) {
    const content = stripEol(lines[i]);
    if (fence.consume(content)) continue;
    if (fence.inside()) continue;
    const m = /^[ \t]*[-*+][ \t]+(.*)$/.exec(content);
    if (m) out.push(m[1]);
  }
  return out;
}

function patchListSection(
  raw: string,
  field: RulesField,
  heading: string,
  oldList: readonly string[],
  newList: readonly string[]
): RulesPatchResult {
  const sections = splitMarkdownSections(raw);
  const indices = findSectionIndices(sections, 2, heading);
  if (indices.length === 0)
    return { ok: false, failure: { field, reason: "section-not-found" } };
  if (indices.length > 1)
    return { ok: false, failure: { field, reason: "multiple-sections" } };

  const idx = indices[0];
  const section = sections[idx];
  const lines = splitLinesPreserveEndings(section.raw);
  const runs = findBulletRuns(lines, 1);

  if (runs.length > 1)
    return { ok: false, failure: { field, reason: "multiple-bullet-runs" } };

  if (runs.length === 1) {
    const result = patchBulletRunInSection(
      raw,
      { level: 2, heading },
      newList
    );
    if (!result.ok) {
      const reason: RulesPatchReason =
        result.reason === "no-bullet-run"
          ? "multiple-bullet-runs"
          : result.reason === "section-not-found"
            ? "section-not-found"
            : result.reason === "multiple-sections"
              ? "multiple-sections"
              : "multiple-bullet-runs";
      return { ok: false, failure: { field, reason } };
    }
    return { ok: true, raw: result.raw };
  }

  // No bullet runs: only allow insertion when the parsed old list was empty
  // (i.e. we are filling in a previously-empty managed section).
  if (oldList.length !== 0)
    return { ok: false, failure: { field, reason: "multiple-bullet-runs" } };
  if (newList.length === 0) return { ok: true, raw };

  const eol = detectEol(raw);
  const headingLine = lines[0] ?? "";
  const headingHasEol = lineEol(headingLine) !== "";
  const fixedHeading = headingHasEol ? headingLine : headingLine + eol;
  const newBulletLines = newList.map((b) => `- ${b}${eol}`);
  const newLines = [fixedHeading, ...newBulletLines, ...lines.slice(1)];

  return {
    ok: true,
    raw: replaceSection(sections, idx, { ...section, raw: newLines.join("") }),
  };
}

function findBulletRuns(
  lines: readonly string[],
  startIdx: number
): { start: number; end: number }[] {
  const runs: { start: number; end: number }[] = [];
  const fence = createFenceState();
  let i = startIdx;
  while (i < lines.length) {
    const content = stripEol(lines[i]);
    if (fence.consume(content)) {
      i++;
      continue;
    }
    if (fence.inside()) {
      i++;
      continue;
    }
    if (isBulletContent(content)) {
      let j = i + 1;
      while (j < lines.length && isBulletContent(stripEol(lines[j]))) {
        j++;
      }
      runs.push({ start: i, end: j });
      i = j;
    } else {
      i++;
    }
  }
  return runs;
}

function findSectionIndices(
  sections: readonly MarkdownSection[],
  level: number,
  heading: string
): number[] {
  const out: number[] = [];
  for (let i = 0; i < sections.length; i++) {
    const s = sections[i];
    if (s.level === level && s.heading === heading) out.push(i);
  }
  return out;
}

function replaceSection(
  sections: readonly MarkdownSection[],
  idx: number,
  next: MarkdownSection
): string {
  return joinMarkdownSections([
    ...sections.slice(0, idx),
    next,
    ...sections.slice(idx + 1),
  ]);
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

function isBulletContent(content: string): boolean {
  return /^[ \t]*[-*+][ \t]+/.test(content);
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
