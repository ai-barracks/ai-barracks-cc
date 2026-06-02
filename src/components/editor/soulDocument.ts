import {
  detectEol,
  splitLinesPreserveEndings,
  splitMarkdownSections,
  joinMarkdownSections,
  patchBulletRunInSection,
  type MarkdownSection,
} from "./documentPatch";

export interface SoulData {
  name: string;
  expertise: string[];
  personality: string[];
  core_values: string[];
  constraints: string[];
}

export interface SoulDocument {
  readonly raw: string;
  readonly data: SoulData;
}

export type SoulField =
  | "name"
  | "expertise"
  | "personality"
  | "core_values"
  | "constraints";

export type SoulPatchReason =
  | "section-not-found"
  | "multiple-sections"
  | "multiple-bullet-runs";

export interface SoulPatchFailure {
  readonly field: SoulField;
  readonly reason: SoulPatchReason;
}

export type SoulPatchResult =
  | { readonly ok: true; readonly raw: string }
  | { readonly ok: false; readonly failure: SoulPatchFailure };

const LIST_FIELDS: ReadonlyArray<{
  field: Exclude<SoulField, "name">;
  heading: string;
}> = [
  { field: "expertise", heading: "Expertise" },
  { field: "personality", heading: "Personality" },
  { field: "core_values", heading: "Core Values" },
  { field: "constraints", heading: "Constraints" },
];

export function parseSoulDocument(raw: string): SoulDocument {
  return { raw, data: parseSoulData(raw) };
}

export function patchSoulDocument(
  raw: string,
  next: SoulData
): SoulPatchResult {
  const prev = parseSoulData(raw);
  let current = raw;

  if (prev.name !== next.name) {
    const r = patchNameSection(current, next.name);
    if (!r.ok) return r;
    current = r.raw;
  }

  for (const spec of LIST_FIELDS) {
    const oldList = prev[spec.field];
    const newList = next[spec.field];
    if (arraysEqual(oldList, newList)) continue;
    const r = patchListSection(current, spec.field, spec.heading, oldList, newList);
    if (!r.ok) return r;
    current = r.raw;
  }

  return { ok: true, raw: current };
}

function parseSoulData(raw: string): SoulData {
  const data: SoulData = {
    name: "",
    expertise: [],
    personality: [],
    core_values: [],
    constraints: [],
  };
  const sections = splitMarkdownSections(raw);
  for (const section of sections) {
    if (section.level !== 2 || section.heading === null) continue;
    switch (section.heading) {
      case "Name":
        data.name = extractFirstManagedLine(section.raw);
        break;
      case "Expertise":
        data.expertise = extractManagedBullets(section.raw);
        break;
      case "Personality":
        data.personality = extractManagedBullets(section.raw);
        break;
      case "Core Values":
        data.core_values = extractManagedBullets(section.raw);
        break;
      case "Constraints":
        data.constraints = extractManagedBullets(section.raw);
        break;
      default:
        break;
    }
  }
  return data;
}

function extractFirstManagedLine(sectionRaw: string): string {
  const lines = splitLinesPreserveEndings(sectionRaw);
  const fence = createFenceState();
  for (let i = 1; i < lines.length; i++) {
    const content = stripEol(lines[i]);
    if (fence.consume(content)) continue;
    if (fence.inside()) continue;
    const trimmed = content.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith("<!--")) continue;
    return trimmed;
  }
  return "";
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

function patchNameSection(raw: string, newName: string): SoulPatchResult {
  const sections = splitMarkdownSections(raw);
  const indices = findSectionIndices(sections, 2, "Name");
  if (indices.length === 0)
    return { ok: false, failure: { field: "name", reason: "section-not-found" } };
  if (indices.length > 1)
    return { ok: false, failure: { field: "name", reason: "multiple-sections" } };

  const idx = indices[0];
  const section = sections[idx];
  const lines = splitLinesPreserveEndings(section.raw);
  const lineIdx = findManagedLineIndex(lines);

  let newLines: string[];
  if (lineIdx !== -1) {
    if (newName === "") {
      newLines = [...lines.slice(0, lineIdx), ...lines.slice(lineIdx + 1)];
    } else {
      const oldEol = lineEol(lines[lineIdx]);
      newLines = [...lines];
      newLines[lineIdx] = `${newName}${oldEol}`;
    }
  } else {
    if (newName === "") return { ok: true, raw };
    const eol = detectEol(raw);
    const headingLine = lines[0] ?? "";
    const headingHasEol = lineEol(headingLine) !== "";
    const fixedHeading = headingHasEol ? headingLine : headingLine + eol;
    newLines = [fixedHeading, `${newName}${eol}`, ...lines.slice(1)];
  }

  return {
    ok: true,
    raw: replaceSection(sections, idx, { ...section, raw: newLines.join("") }),
  };
}

function patchListSection(
  raw: string,
  field: Exclude<SoulField, "name">,
  heading: string,
  oldList: readonly string[],
  newList: readonly string[]
): SoulPatchResult {
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
      const reason: SoulPatchReason =
        result.reason === "no-bullet-run" ? "multiple-bullet-runs" : result.reason;
      return { ok: false, failure: { field, reason } };
    }
    return { ok: true, raw: result.raw };
  }

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

function findManagedLineIndex(lines: readonly string[]): number {
  const fence = createFenceState();
  for (let i = 1; i < lines.length; i++) {
    const content = stripEol(lines[i]);
    if (fence.consume(content)) continue;
    if (fence.inside()) continue;
    const trimmed = content.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith("<!--")) continue;
    return i;
  }
  return -1;
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
