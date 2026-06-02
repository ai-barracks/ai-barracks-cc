import { describe, it, expect } from "vitest";
import {
  detectEol,
  splitLinesPreserveEndings,
  joinLines,
  splitMarkdownSections,
  joinMarkdownSections,
  findSection,
  patchBulletRunInSection,
} from "./documentPatch";

describe("splitLinesPreserveEndings + joinLines round-trip", () => {
  const cases: { name: string; raw: string }[] = [
    { name: "empty string", raw: "" },
    { name: "single line, no newline", raw: "hello" },
    { name: "LF only with trailing", raw: "a\nb\nc\n" },
    { name: "LF only, no trailing", raw: "a\nb\nc" },
    { name: "CRLF only with trailing", raw: "a\r\nb\r\nc\r\n" },
    { name: "mixed final no-newline", raw: "a\r\nb\nc" },
    { name: "blank lines preserved", raw: "\n\nfoo\n\n\nbar\n" },
    { name: "trailing newline only", raw: "\n" },
    { name: "CRLF trailing only", raw: "\r\n" },
    { name: "Korean + emoji mixed EOL", raw: "안녕\n세계 🌏\nテスト\r\n" },
    { name: "emoji without final newline", raw: "🎉\n🌟 done" },
  ];
  for (const c of cases) {
    it(`round-trips ${c.name}`, () => {
      expect(joinLines(splitLinesPreserveEndings(c.raw))).toBe(c.raw);
    });
  }
});

describe("detectEol", () => {
  it("defaults to LF when there are no newlines", () => {
    expect(detectEol("")).toBe("\n");
    expect(detectEol("hello world")).toBe("\n");
  });
  it("returns LF when LF dominates", () => {
    expect(detectEol("a\nb\nc\r\n")).toBe("\n");
  });
  it("returns CRLF when CRLF dominates", () => {
    expect(detectEol("a\r\nb\r\nc\n")).toBe("\r\n");
  });
  it("returns LF on tie (default)", () => {
    expect(detectEol("a\nb\r\n")).toBe("\n");
  });
});

describe("splitMarkdownSections + joinMarkdownSections round-trip", () => {
  it("preserves bytes exactly for a fixture with preamble, comments, multiple headings, fenced code, CRLF, and no trailing newline", () => {
    const fixture = [
      "<!-- ownership: human -->",
      "preamble line",
      "",
      "# Top",
      "para under top",
      "",
      "```js",
      "// fenced code",
      "## Not a heading",
      "```",
      "",
      "## Sub A",
      "<!-- in-section comment -->",
      "- bullet 1",
      "- bullet 2",
      "",
      "## Sub B",
      "no bullets here",
    ].join("\r\n");
    expect(joinMarkdownSections(splitMarkdownSections(fixture))).toBe(fixture);
  });

  it("preserves empty input", () => {
    expect(joinMarkdownSections(splitMarkdownSections(""))).toBe("");
  });

  it("preserves a doc with no headings (all preamble)", () => {
    const raw = "just\nsome\nlines\n";
    expect(joinMarkdownSections(splitMarkdownSections(raw))).toBe(raw);
    const secs = splitMarkdownSections(raw);
    expect(secs).toHaveLength(1);
    expect(secs[0].level).toBe(0);
    expect(secs[0].heading).toBeNull();
  });

  it("does not treat headings inside fenced code blocks as sections", () => {
    const raw =
      "# Real\n\n```\n## Fake heading\n### Also fake\n```\n## After\nbody\n";
    const sections = splitMarkdownSections(raw);
    expect(sections.map((s) => s.heading)).toEqual([null, "Real", "After"]);
    expect(joinMarkdownSections(sections)).toBe(raw);
  });

  it("supports tilde fences as well as backticks", () => {
    const raw = "# A\n~~~\n## Inside\n~~~\n## B\n";
    const sections = splitMarkdownSections(raw);
    expect(sections.map((s) => s.heading)).toEqual([null, "A", "B"]);
    expect(joinMarkdownSections(sections)).toBe(raw);
  });

  it("treats trailing # as content unless preceded by whitespace", () => {
    const raw = "## C#\nbody for c sharp\n## Title ###\nbody for title\n";
    const sections = splitMarkdownSections(raw);
    expect(sections.map((s) => s.heading)).toEqual([null, "C#", "Title"]);
    expect(sections.map((s) => s.level)).toEqual([0, 2, 2]);
    expect(joinMarkdownSections(sections)).toBe(raw);
  });

  it("does not close a 4-backtick fence with a 3-backtick line", () => {
    const raw = [
      "# Real",
      "",
      "````",
      "```",
      "## Fake",
      "```",
      "````",
      "",
      "## After",
      "tail",
      "",
    ].join("\n");
    const sections = splitMarkdownSections(raw);
    expect(sections.map((s) => s.heading)).toEqual([null, "Real", "After"]);
    expect(joinMarkdownSections(sections)).toBe(raw);
  });
});

describe("findSection", () => {
  const raw = "# Top\nintro\n## A\nbody a\n## B\nbody b\n### C\nbody c\n";
  const sections = splitMarkdownSections(raw);

  it("finds by exact heading text and level", () => {
    const a = findSection(sections, 2, "A");
    expect(a).not.toBeNull();
    expect(a?.heading).toBe("A");
    expect(a?.level).toBe(2);

    const c = findSection(sections, 3, "C");
    expect(c?.heading).toBe("C");
    expect(c?.level).toBe(3);
  });

  it("returns null when heading is missing", () => {
    expect(findSection(sections, 2, "Z")).toBeNull();
  });

  it("returns null when level mismatches", () => {
    expect(findSection(sections, 3, "A")).toBeNull();
    expect(findSection(sections, 2, "C")).toBeNull();
  });
});

describe("patchBulletRunInSection", () => {
  const baseLF = [
    "<!-- ownership: human -->",
    "intro paragraph",
    "",
    "## Must Always",
    "<!-- note inside section -->",
    "- old one",
    "- old two",
    "",
    "trailing prose",
    "",
    "## Must Never",
    "- forbidden",
    "",
  ].join("\n");

  it("replaces only the bullet run, preserving comments and prose before and after", () => {
    const r = patchBulletRunInSection(
      baseLF,
      { level: 2, heading: "Must Always" },
      ["new alpha", "new beta", "new gamma"]
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain("- new alpha\n- new beta\n- new gamma\n");
    expect(r.raw).toContain("<!-- ownership: human -->");
    expect(r.raw).toContain("intro paragraph");
    expect(r.raw).toContain("<!-- note inside section -->");
    expect(r.raw).toContain("trailing prose");
    expect(r.raw).toContain("## Must Never\n- forbidden");
    expect(r.raw).not.toContain("- old one");
    expect(r.raw).not.toContain("- old two");
  });

  it("is a no-op when the new bullets equal the old bullets", () => {
    const r = patchBulletRunInSection(
      baseLF,
      { level: 2, heading: "Must Always" },
      ["old one", "old two"]
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toBe(baseLF);
  });

  it("preserves CRLF EOL style across the patched document", () => {
    const baseCRLF = baseLF.replace(/\n/g, "\r\n");
    const r = patchBulletRunInSection(
      baseCRLF,
      { level: 2, heading: "Must Always" },
      ["x", "y"]
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain("- x\r\n- y\r\n");
    expect(r.raw.replace(/\r\n/g, "").includes("\n")).toBe(false);
  });

  it("preserves an indented bullet style (e.g. '  * ')", () => {
    const raw = "## List\nintro\n\n  * one\n  * two\n\ntail\n";
    const r = patchBulletRunInSection(
      raw,
      { level: 2, heading: "List" },
      ["alpha", "beta"]
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain("  * alpha\n  * beta\n");
    expect(r.raw).toContain("tail");
  });

  it("fails closed when the section is not found", () => {
    const r = patchBulletRunInSection(
      baseLF,
      { level: 2, heading: "Does Not Exist" },
      ["x"]
    );
    expect(r).toEqual({ ok: false, reason: "section-not-found" });
  });

  it("fails closed when the section has no bullets", () => {
    const raw = "## Empty\nprose only\n\n## Next\n- ok\n";
    const r = patchBulletRunInSection(
      raw,
      { level: 2, heading: "Empty" },
      ["x"]
    );
    expect(r).toEqual({ ok: false, reason: "no-bullet-run" });
  });

  it("fails closed when more than one section matches the same level+heading", () => {
    const raw = [
      "## Must Always",
      "- a",
      "- b",
      "",
      "## Other",
      "prose",
      "",
      "## Must Always",
      "- c",
      "- d",
      "",
    ].join("\n");
    const r = patchBulletRunInSection(
      raw,
      { level: 2, heading: "Must Always" },
      ["x"]
    );
    expect(r).toEqual({ ok: false, reason: "multiple-sections" });
  });

  it("ignores bullet-looking lines inside fenced code blocks and patches only the real run", () => {
    const raw = [
      "## Notes",
      "intro",
      "",
      "```",
      "- not a managed bullet",
      "```",
      "",
      "- real one",
      "- real two",
      "",
      "tail",
      "",
    ].join("\n");
    const codeBlock = "```\n- not a managed bullet\n```";
    const r = patchBulletRunInSection(
      raw,
      { level: 2, heading: "Notes" },
      ["alpha", "beta"]
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.raw).toContain(codeBlock);
    expect(r.raw).toContain("- alpha\n- beta\n");
    expect(r.raw).not.toContain("- real one");
    expect(r.raw).not.toContain("- real two");
    expect(r.raw).toContain("tail");
  });

  it("fails closed with no-bullet-run when bullets only appear inside fenced code", () => {
    const raw = [
      "## Notes",
      "intro",
      "",
      "```",
      "- inside code one",
      "- inside code two",
      "```",
      "",
      "tail",
      "",
    ].join("\n");
    const r = patchBulletRunInSection(
      raw,
      { level: 2, heading: "Notes" },
      ["x"]
    );
    expect(r).toEqual({ ok: false, reason: "no-bullet-run" });
    // ensure the code block bytes would still be intact had we patched (sanity: input unchanged in failure path is implicit, but we assert the original still contains the code block).
    expect(raw).toContain("```\n- inside code one\n- inside code two\n```");
  });

  it("fails closed when the section has multiple bullet runs", () => {
    const raw = [
      "## Two Runs",
      "- a",
      "- b",
      "",
      "interruption",
      "",
      "- c",
      "- d",
      "",
    ].join("\n");
    const r = patchBulletRunInSection(
      raw,
      { level: 2, heading: "Two Runs" },
      ["x"]
    );
    expect(r).toEqual({ ok: false, reason: "multiple-bullet-runs" });
  });
});
