import { describe, it, expect } from "vitest";
import {
  parseSoulDocument,
  patchSoulDocument,
  type SoulData,
} from "./soulDocument";

const RICH_FIXTURE_LF = [
  "<!-- AIB:SOUL:v1 — keep this structure -->",
  "# Agent Identity",
  "",
  "## Name",
  "<!-- pinned name below -->",
  "Aria",
  "",
  "## Expertise",
  "- TypeScript",
  "- React",
  "",
  "## Personality",
  "- calm",
  "- precise",
  "",
  "## Core Values",
  "- truth",
  "- clarity",
  "",
  "## Constraints",
  "- ko-first",
  "",
  "## Notes",
  "custom section content",
  "```python",
  "- not a managed bullet",
  "```",
  "",
  "<!-- AIB:SOUL:END -->",
].join("\n");

// No trailing newline on the comment marker — exercises preserve-EOL behavior.
const RICH_FIXTURE_CRLF_NOEOL = RICH_FIXTURE_LF.replace(/\n/g, "\r\n");

describe("parseSoulDocument", () => {
  it("extracts name, expertise, personality, core_values, constraints", () => {
    const { data } = parseSoulDocument(RICH_FIXTURE_LF);
    expect(data.name).toBe("Aria");
    expect(data.expertise).toEqual(["TypeScript", "React"]);
    expect(data.personality).toEqual(["calm", "precise"]);
    expect(data.core_values).toEqual(["truth", "clarity"]);
    expect(data.constraints).toEqual(["ko-first"]);
  });

  it("ignores bullet-looking lines inside fenced code blocks", () => {
    const raw = [
      "## Expertise",
      "",
      "```",
      "- not a managed bullet",
      "- another fake",
      "```",
      "",
      "- TypeScript",
      "- React",
      "",
    ].join("\n");
    const { data } = parseSoulDocument(raw);
    expect(data.expertise).toEqual(["TypeScript", "React"]);
  });

  it("skips comments and empty lines when locating the managed name line", () => {
    const raw = [
      "## Name",
      "",
      "<!-- ownership: human -->",
      "",
      "Real Name",
      "secondary line",
    ].join("\n");
    const { data } = parseSoulDocument(raw);
    expect(data.name).toBe("Real Name");
  });

  it("returns empty arrays / empty name when sections are absent", () => {
    const { data } = parseSoulDocument("# Title only\n");
    expect(data.name).toBe("");
    expect(data.expertise).toEqual([]);
    expect(data.personality).toEqual([]);
    expect(data.core_values).toEqual([]);
    expect(data.constraints).toEqual([]);
  });
});

describe("patchSoulDocument byte-identical roundtrip", () => {
  it("returns the original raw when data is unchanged (LF, with comments + custom section + code fence)", () => {
    const doc = parseSoulDocument(RICH_FIXTURE_LF);
    const r = patchSoulDocument(RICH_FIXTURE_LF, doc.data);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.raw).toBe(RICH_FIXTURE_LF);
  });

  it("returns the original raw when data is unchanged (CRLF, no trailing newline)", () => {
    const doc = parseSoulDocument(RICH_FIXTURE_CRLF_NOEOL);
    const r = patchSoulDocument(RICH_FIXTURE_CRLF_NOEOL, doc.data);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.raw).toBe(RICH_FIXTURE_CRLF_NOEOL);
  });
});

describe("patchSoulDocument list changes", () => {
  it("updates only the targeted bullet run and preserves the rest verbatim", () => {
    const { data } = parseSoulDocument(RICH_FIXTURE_LF);
    const next: SoulData = { ...data, expertise: ["TypeScript", "React", "Vitest"] };
    const r = patchSoulDocument(RICH_FIXTURE_LF, next);
    expect(r.ok).toBe(true);
    if (!r.ok) return;

    // The expertise run is replaced atomically.
    expect(r.raw).toContain("## Expertise\n- TypeScript\n- React\n- Vitest\n");

    // Other managed runs are untouched verbatim.
    expect(r.raw).toContain("## Personality\n- calm\n- precise\n");
    expect(r.raw).toContain("## Core Values\n- truth\n- clarity\n");
    expect(r.raw).toContain("## Constraints\n- ko-first\n");

    // Comments, custom section, code fence, and end marker preserved.
    expect(r.raw).toContain("<!-- AIB:SOUL:v1 — keep this structure -->");
    expect(r.raw).toContain("<!-- pinned name below -->\nAria\n");
    expect(r.raw).toContain("## Notes\ncustom section content\n```python\n- not a managed bullet\n```");
    expect(r.raw).toContain("<!-- AIB:SOUL:END -->");
  });

  it("leaves fenced code bullets intact when patching the managed bullet run", () => {
    const raw = [
      "## Expertise",
      "",
      "```",
      "- not a managed bullet",
      "```",
      "",
      "- TypeScript",
      "- React",
      "",
    ].join("\n");
    const fenceBlock = "```\n- not a managed bullet\n```";
    const r = patchSoulDocument(raw, {
      name: "",
      expertise: ["alpha", "beta"],
      personality: [],
      core_values: [],
      constraints: [],
    });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain(fenceBlock);
    expect(r.raw).toContain("- alpha\n- beta\n");
    expect(r.raw).not.toContain("- TypeScript");
    expect(r.raw).not.toContain("- React");
  });

  it("inserts first bullets into an empty list section without rebuilding the file", () => {
    const raw = [
      "<!-- preamble comment -->",
      "# Identity",
      "",
      "## Name",
      "Aria",
      "",
      "## Expertise",
      "- TypeScript",
      "",
      "## Personality",
      "- calm",
      "",
      "## Core Values",
      "- truth",
      "",
      "## Constraints",
      "",
      "## Notes",
      "custom",
      "",
    ].join("\n");
    const { data } = parseSoulDocument(raw);
    expect(data.constraints).toEqual([]);

    const r = patchSoulDocument(raw, { ...data, constraints: ["ko-first", "no PII"] });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain("## Constraints\n- ko-first\n- no PII\n");
    // Other sections and surrounding content are byte-identical.
    expect(r.raw).toContain("<!-- preamble comment -->");
    expect(r.raw).toContain("## Expertise\n- TypeScript\n");
    expect(r.raw).toContain("## Personality\n- calm\n");
    expect(r.raw).toContain("## Core Values\n- truth\n");
    expect(r.raw).toContain("## Notes\ncustom\n");
  });

  it("is a no-op when an empty list stays empty", () => {
    const raw = [
      "## Name",
      "Aria",
      "",
      "## Expertise",
      "- TypeScript",
      "",
      "## Constraints",
      "",
    ].join("\n");
    const { data } = parseSoulDocument(raw);
    const r = patchSoulDocument(raw, data);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.raw).toBe(raw);
  });
});

describe("patchSoulDocument name changes", () => {
  it("updates only the managed name line and keeps surrounding comments/prose intact", () => {
    const { data } = parseSoulDocument(RICH_FIXTURE_LF);
    const r = patchSoulDocument(RICH_FIXTURE_LF, { ...data, name: "Nyx" });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain("## Name\n<!-- pinned name below -->\nNyx\n");
    expect(r.raw).not.toContain("Aria");
    // List sections are untouched.
    expect(r.raw).toContain("## Expertise\n- TypeScript\n- React\n");
    expect(r.raw).toContain("## Constraints\n- ko-first\n");
    expect(r.raw).toContain("<!-- AIB:SOUL:END -->");
  });

  it("inserts a managed name when the Name section is empty", () => {
    const raw = [
      "## Name",
      "<!-- pending -->",
      "",
      "## Expertise",
      "- TS",
      "",
    ].join("\n");
    const { data } = parseSoulDocument(raw);
    expect(data.name).toBe("");
    const r = patchSoulDocument(raw, { ...data, name: "Aria" });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain("## Name\nAria\n<!-- pending -->\n");
    expect(r.raw).toContain("## Expertise\n- TS\n");
  });
});

describe("patchSoulDocument fail-closed behavior", () => {
  it("fails closed with section-not-found when the changed list section is missing", () => {
    const raw = [
      "## Name",
      "Aria",
      "",
      "## Expertise",
      "- TS",
      "",
      "## Personality",
      "- calm",
      "",
      "## Core Values",
      "- truth",
      "",
      // No Constraints section.
    ].join("\n");
    const { data } = parseSoulDocument(raw);
    const r = patchSoulDocument(raw, { ...data, constraints: ["ko-first"] });
    expect(r).toEqual({
      ok: false,
      failure: { field: "constraints", reason: "section-not-found" },
    });
  });

  it("fails closed with multiple-sections when a managed heading appears more than once", () => {
    const raw = [
      "## Name",
      "Aria",
      "",
      "## Expertise",
      "- TS",
      "",
      "## Expertise",
      "- duplicate",
      "",
      "## Personality",
      "- calm",
      "",
      "## Core Values",
      "- truth",
      "",
      "## Constraints",
      "- ko-first",
      "",
    ].join("\n");
    const { data } = parseSoulDocument(raw);
    const r = patchSoulDocument(raw, { ...data, expertise: ["x"] });
    expect(r).toEqual({
      ok: false,
      failure: { field: "expertise", reason: "multiple-sections" },
    });
  });

  it("fails closed with multiple-bullet-runs when a changed list section has two non-code bullet runs", () => {
    const raw = [
      "## Name",
      "Aria",
      "",
      "## Expertise",
      "- TS",
      "- React",
      "",
      "interruption prose",
      "",
      "- extra",
      "",
      "## Personality",
      "- calm",
      "",
      "## Core Values",
      "- truth",
      "",
      "## Constraints",
      "- ko-first",
      "",
    ].join("\n");
    const { data } = parseSoulDocument(raw);
    const r = patchSoulDocument(raw, { ...data, expertise: ["x"] });
    expect(r).toEqual({
      ok: false,
      failure: { field: "expertise", reason: "multiple-bullet-runs" },
    });
  });

  it("fails closed with section-not-found when name section is missing and name changes", () => {
    const raw = [
      "## Expertise",
      "- TS",
      "",
    ].join("\n");
    const { data } = parseSoulDocument(raw);
    const r = patchSoulDocument(raw, { ...data, name: "Aria" });
    expect(r).toEqual({
      ok: false,
      failure: { field: "name", reason: "section-not-found" },
    });
  });
});
