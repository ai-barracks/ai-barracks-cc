import { describe, it, expect } from "vitest";
import {
  parseRulesDocument,
  patchRulesDocument,
  emptyRulesTemplate,
  type RulesData,
} from "./rulesDocument";

const RICH_FIXTURE_LF = [
  "<!-- AIB:RULES:v1 — auto-accumulated -->",
  "# Rules",
  "",
  "preamble prose",
  "",
  "## Must Always",
  "<!-- pinned by ops -->",
  "- communicate in Korean",
  "- write tests",
  "",
  "## Must Never",
  "- skip code review",
  "- bypass hooks",
  "",
  "## Learned",
  "- log before mutating shared state",
  "",
  "## Notes",
  "custom section content",
  "```python",
  "- not a managed bullet",
  "```",
  "",
  "<!-- AIB:RULES:END -->",
].join("\n");

const RICH_FIXTURE_CRLF_NOEOL = RICH_FIXTURE_LF.replace(/\n/g, "\r\n");

describe("parseRulesDocument", () => {
  it("extracts must_always, must_never, learned bullets", () => {
    const { data } = parseRulesDocument(RICH_FIXTURE_LF);
    expect(data.must_always).toEqual([
      "communicate in Korean",
      "write tests",
    ]);
    expect(data.must_never).toEqual(["skip code review", "bypass hooks"]);
    expect(data.learned).toEqual(["log before mutating shared state"]);
  });

  it("returns empty arrays when sections are absent", () => {
    const { data } = parseRulesDocument("# Title only\n");
    expect(data.must_always).toEqual([]);
    expect(data.must_never).toEqual([]);
    expect(data.learned).toEqual([]);
  });

  it("returns empty arrays for empty input", () => {
    const { data } = parseRulesDocument("");
    expect(data.must_always).toEqual([]);
    expect(data.must_never).toEqual([]);
    expect(data.learned).toEqual([]);
  });

  it("ignores bullet-looking lines inside fenced code blocks", () => {
    const raw = [
      "## Must Always",
      "",
      "```",
      "- not a managed bullet",
      "- another fake",
      "```",
      "",
      "- real one",
      "- real two",
      "",
    ].join("\n");
    const { data } = parseRulesDocument(raw);
    expect(data.must_always).toEqual(["real one", "real two"]);
  });

  it("ignores comments and unknown sections for UI data but preserves raw", () => {
    const { raw, data } = parseRulesDocument(RICH_FIXTURE_LF);
    expect(raw).toBe(RICH_FIXTURE_LF);
    // Notes section content is not surfaced in data.
    expect(JSON.stringify(data)).not.toContain("custom section content");
  });
});

describe("patchRulesDocument byte-identical roundtrip", () => {
  it("returns the original raw when data is unchanged (LF, comments + custom + code fence)", () => {
    const doc = parseRulesDocument(RICH_FIXTURE_LF);
    const r = patchRulesDocument(RICH_FIXTURE_LF, doc.data);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.raw).toBe(RICH_FIXTURE_LF);
  });

  it("returns the original raw when data is unchanged (CRLF, no trailing newline)", () => {
    const doc = parseRulesDocument(RICH_FIXTURE_CRLF_NOEOL);
    const r = patchRulesDocument(RICH_FIXTURE_CRLF_NOEOL, doc.data);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.raw).toBe(RICH_FIXTURE_CRLF_NOEOL);
  });
});

describe("patchRulesDocument list changes", () => {
  it("updates only one section, preserving comments, custom sections, and end marker", () => {
    const { data } = parseRulesDocument(RICH_FIXTURE_LF);
    const next: RulesData = {
      ...data,
      must_always: ["communicate in Korean", "write tests", "use timezones"],
    };
    const r = patchRulesDocument(RICH_FIXTURE_LF, next);
    expect(r.ok).toBe(true);
    if (!r.ok) return;

    expect(r.raw).toContain(
      "## Must Always\n<!-- pinned by ops -->\n- communicate in Korean\n- write tests\n- use timezones\n"
    );
    // Other managed sections are byte-identical.
    expect(r.raw).toContain("## Must Never\n- skip code review\n- bypass hooks\n");
    expect(r.raw).toContain("## Learned\n- log before mutating shared state\n");
    // Comments, custom section, fenced code, end marker preserved.
    expect(r.raw).toContain("<!-- AIB:RULES:v1 — auto-accumulated -->");
    expect(r.raw).toContain(
      "## Notes\ncustom section content\n```python\n- not a managed bullet\n```"
    );
    expect(r.raw).toContain("<!-- AIB:RULES:END -->");
    expect(r.raw).toContain("preamble prose");
  });

  it("preserves fenced-code bullets inside a managed section when patching its real bullet run", () => {
    const raw = [
      "## Must Always",
      "",
      "```",
      "- not a managed bullet",
      "```",
      "",
      "- real one",
      "- real two",
      "",
    ].join("\n");
    const fenceBlock = "```\n- not a managed bullet\n```";
    const r = patchRulesDocument(raw, {
      must_always: ["alpha", "beta"],
      must_never: [],
      learned: [],
    });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain(fenceBlock);
    expect(r.raw).toContain("- alpha\n- beta\n");
    expect(r.raw).not.toContain("- real one");
    expect(r.raw).not.toContain("- real two");
  });

  it("inserts first bullets into an empty managed section without rebuilding the file", () => {
    const raw = [
      "<!-- preamble -->",
      "# Rules",
      "",
      "## Must Always",
      "- communicate in Korean",
      "",
      "## Must Never",
      "- skip review",
      "",
      "## Learned",
      "",
      "## Notes",
      "custom",
      "",
    ].join("\n");
    const { data } = parseRulesDocument(raw);
    expect(data.learned).toEqual([]);

    const r = patchRulesDocument(raw, {
      ...data,
      learned: ["always log", "never trust input"],
    });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain(
      "## Learned\n- always log\n- never trust input\n"
    );
    expect(r.raw).toContain("<!-- preamble -->");
    expect(r.raw).toContain("## Must Always\n- communicate in Korean\n");
    expect(r.raw).toContain("## Must Never\n- skip review\n");
    expect(r.raw).toContain("## Notes\ncustom\n");
  });

  it("is a no-op when an empty list stays empty", () => {
    const raw = [
      "## Must Always",
      "- a",
      "",
      "## Must Never",
      "",
      "## Learned",
      "- l",
      "",
    ].join("\n");
    const { data } = parseRulesDocument(raw);
    const r = patchRulesDocument(raw, data);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.raw).toBe(raw);
  });
});

describe("patchRulesDocument empty raw template", () => {
  it("creates a minimal RULES.md template when raw is empty and data has bullets", () => {
    const r = patchRulesDocument("", {
      must_always: ["communicate in Korean"],
      must_never: ["skip review"],
      learned: ["always log"],
    });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain("# Rules");
    expect(r.raw).toContain("## Must Always\n- communicate in Korean\n");
    expect(r.raw).toContain("## Must Never\n- skip review\n");
    expect(r.raw).toContain("## Learned\n- always log\n");
  });

  it("returns the template when raw is empty and data is also empty (no-changes-from-template)", () => {
    const r = patchRulesDocument("", {
      must_always: [],
      must_never: [],
      learned: [],
    });
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.raw).toBe(emptyRulesTemplate());
  });
});

describe("patchRulesDocument fail-closed behavior", () => {
  it("fails closed with section-not-found when a changed list section is missing", () => {
    const raw = [
      "# Rules",
      "",
      "## Must Always",
      "- a",
      "",
      "## Must Never",
      "- n",
      "",
      // No Learned section.
    ].join("\n");
    const { data } = parseRulesDocument(raw);
    const r = patchRulesDocument(raw, { ...data, learned: ["x"] });
    expect(r).toEqual({
      ok: false,
      failure: { field: "learned", reason: "section-not-found" },
    });
  });

  it("fails closed with multiple-sections when a managed heading appears more than once", () => {
    const raw = [
      "## Must Always",
      "- a",
      "",
      "## Must Always",
      "- dup",
      "",
      "## Must Never",
      "- n",
      "",
      "## Learned",
      "- l",
      "",
    ].join("\n");
    const { data } = parseRulesDocument(raw);
    const r = patchRulesDocument(raw, { ...data, must_always: ["x"] });
    expect(r).toEqual({
      ok: false,
      failure: { field: "must_always", reason: "multiple-sections" },
    });
  });

  it("fails closed with multiple-bullet-runs when a changed section has two non-code bullet runs", () => {
    const raw = [
      "## Must Always",
      "- a",
      "- b",
      "",
      "interruption prose",
      "",
      "- extra",
      "",
      "## Must Never",
      "- n",
      "",
      "## Learned",
      "- l",
      "",
    ].join("\n");
    const { data } = parseRulesDocument(raw);
    const r = patchRulesDocument(raw, { ...data, must_always: ["x"] });
    expect(r).toEqual({
      ok: false,
      failure: { field: "must_always", reason: "multiple-bullet-runs" },
    });
  });
});
