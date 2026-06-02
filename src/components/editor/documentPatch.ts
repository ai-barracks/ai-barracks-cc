export type Eol = "\n" | "\r\n";

export type MarkdownSection = {
  readonly level: number;
  readonly heading: string | null;
  readonly raw: string;
};

export type PatchFailureReason =
  | "section-not-found"
  | "multiple-sections"
  | "no-bullet-run"
  | "multiple-bullet-runs";

export type PatchResult =
  | { readonly ok: true; readonly raw: string }
  | { readonly ok: false; readonly reason: PatchFailureReason };

export function detectEol(raw: string): Eol {
  let crlf = 0;
  let lf = 0;
  const re = /\r\n|\n/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(raw)) !== null) {
    if (m[0] === "\r\n") crlf++;
    else lf++;
  }
  return crlf > lf ? "\r\n" : "\n";
}

export function splitLinesPreserveEndings(raw: string): string[] {
  if (raw === "") return [];
  const out: string[] = [];
  const re = /\r\n|\n/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(raw)) !== null) {
    out.push(raw.slice(last, m.index + m[0].length));
    last = m.index + m[0].length;
  }
  if (last < raw.length) {
    out.push(raw.slice(last));
  }
  return out;
}

export function joinLines(lines: readonly string[]): string {
  return lines.join("");
}

export function splitMarkdownSections(raw: string): MarkdownSection[] {
  const lines = splitLinesPreserveEndings(raw);
  const sections: MarkdownSection[] = [];
  let level = 0;
  let heading: string | null = null;
  let buf: string[] = [];
  let inFence = false;
  let fenceChar: "`" | "~" | null = null;
  let fenceLen = 0;

  const flush = () => {
    sections.push({ level, heading, raw: buf.join("") });
  };

  for (const line of lines) {
    const content = stripEol(line);
    const fenceMatch = /^ {0,3}(`{3,}|~{3,})/.exec(content);
    if (fenceMatch) {
      const ch = fenceMatch[1][0] as "`" | "~";
      const len = fenceMatch[1].length;
      if (!inFence) {
        inFence = true;
        fenceChar = ch;
        fenceLen = len;
      } else if (ch === fenceChar && len >= fenceLen) {
        inFence = false;
        fenceChar = null;
        fenceLen = 0;
      }
    }
    const headingMatch = !inFence
      ? /^(#{1,6})[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$/.exec(content)
      : null;
    if (headingMatch) {
      flush();
      level = headingMatch[1].length;
      heading = headingMatch[2].trim();
      buf = [line];
    } else {
      buf.push(line);
    }
  }
  flush();
  return sections;
}

export function joinMarkdownSections(
  sections: readonly MarkdownSection[]
): string {
  return sections.map((s) => s.raw).join("");
}

export function findSection(
  sections: readonly MarkdownSection[],
  level: number,
  heading: string
): MarkdownSection | null {
  return (
    sections.find((s) => s.level === level && s.heading === heading) ?? null
  );
}

export function findSectionIndex(
  sections: readonly MarkdownSection[],
  level: number,
  heading: string
): number {
  return sections.findIndex(
    (s) => s.level === level && s.heading === heading
  );
}

export function patchBulletRunInSection(
  raw: string,
  target: { level: number; heading: string },
  newBullets: readonly string[]
): PatchResult {
  const sections = splitMarkdownSections(raw);
  const matchingIndices: number[] = [];
  for (let n = 0; n < sections.length; n++) {
    const s = sections[n];
    if (s.level === target.level && s.heading === target.heading) {
      matchingIndices.push(n);
    }
  }
  if (matchingIndices.length === 0)
    return { ok: false, reason: "section-not-found" };
  if (matchingIndices.length > 1)
    return { ok: false, reason: "multiple-sections" };
  const idx = matchingIndices[0];

  const section = sections[idx];
  const lines = splitLinesPreserveEndings(section.raw);
  const headingOffset = section.level > 0 ? 1 : 0;

  const runs: { start: number; end: number }[] = [];
  let i = headingOffset;
  let inFence = false;
  let fenceChar: "`" | "~" | null = null;
  let fenceLen = 0;
  while (i < lines.length) {
    const fence = matchFenceMarker(lines[i]);
    if (fence) {
      if (!inFence) {
        inFence = true;
        fenceChar = fence.ch;
        fenceLen = fence.len;
      } else if (fence.ch === fenceChar && fence.len >= fenceLen) {
        inFence = false;
        fenceChar = null;
        fenceLen = 0;
      }
      i++;
      continue;
    }
    if (inFence) {
      i++;
      continue;
    }
    if (isBulletLine(lines[i])) {
      let j = i;
      while (j < lines.length && isBulletLine(lines[j])) j++;
      runs.push({ start: i, end: j });
      i = j;
    } else {
      i++;
    }
  }

  if (runs.length === 0) return { ok: false, reason: "no-bullet-run" };
  if (runs.length > 1) return { ok: false, reason: "multiple-bullet-runs" };

  const run = runs[0];
  const style = detectBulletStyle(lines[run.start]);
  if (!style) return { ok: false, reason: "no-bullet-run" };

  let runEol: Eol | null = null;
  for (let k = run.start; k < run.end; k++) {
    const e = detectLineEol(lines[k]);
    if (e) {
      runEol = e;
      break;
    }
  }
  const eol: Eol = runEol ?? detectEol(raw);

  const lastOriginalHasEol = hasEol(lines[run.end - 1]);

  const newBulletLines = newBullets.map((b, k) => {
    const isLast = k === newBullets.length - 1;
    const useEol = isLast && !lastOriginalHasEol ? "" : eol;
    return `${style.indent}${style.marker}${b}${useEol}`;
  });

  const patchedLines = [
    ...lines.slice(0, run.start),
    ...newBulletLines,
    ...lines.slice(run.end),
  ];

  const newSection: MarkdownSection = {
    level: section.level,
    heading: section.heading,
    raw: patchedLines.join(""),
  };

  const newSections = [
    ...sections.slice(0, idx),
    newSection,
    ...sections.slice(idx + 1),
  ];

  return { ok: true, raw: joinMarkdownSections(newSections) };
}

function stripEol(line: string): string {
  if (line.endsWith("\r\n")) return line.slice(0, -2);
  if (line.endsWith("\n")) return line.slice(0, -1);
  return line;
}

function detectLineEol(line: string): Eol | null {
  if (line.endsWith("\r\n")) return "\r\n";
  if (line.endsWith("\n")) return "\n";
  return null;
}

function hasEol(line: string): boolean {
  return line.endsWith("\n");
}

function isBulletLine(line: string): boolean {
  return /^[ \t]*[-*+][ \t]+/.test(stripEol(line));
}

function matchFenceMarker(
  line: string
): { ch: "`" | "~"; len: number } | null {
  const m = /^ {0,3}(`{3,}|~{3,})/.exec(stripEol(line));
  if (!m) return null;
  return { ch: m[1][0] as "`" | "~", len: m[1].length };
}

function detectBulletStyle(
  line: string
): { indent: string; marker: string } | null {
  const m = /^([ \t]*)([-*+][ \t]+)/.exec(stripEol(line));
  if (!m) return null;
  return { indent: m[1], marker: m[2] };
}
