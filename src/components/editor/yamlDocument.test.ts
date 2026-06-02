import { describe, expect, it } from "vitest";
import { parseAgentYamlDocument, patchAgentYamlDocument } from "./yamlDocument";

const RICH = [
  "# agent config",
  "name: old-agent # keep name comment",
  "version: 1.4.0",
  "description: \"Old description # not comment\" # keep desc comment",
  "",
  "models:",
  "  # model comment",
  "  primary: gpt-5.5 # keep primary comment",
  "  fallback:",
  "    - claude-opus-4-8",
  "    - gemini-3",
  "",
  "memory:",
  "  sessions: sessions/",
  "",
  "skills:",
  "  discovery: auto",
  "",
  "custom_policy:",
  "  x: y",
  "",
  "aib_version: 1.1",
].join("\n");

const RICH_CRLF_NOEOL = RICH.replace(/\n/g, "\r\n");

describe("parseAgentYamlDocument", () => {
  it("extracts known scalar/model fields", () => {
    const { data } = parseAgentYamlDocument(RICH);
    expect(data).toEqual({
      name: "old-agent",
      version: "1.4.0",
      description: "Old description # not comment",
      primary_model: "gpt-5.5",
      fallback_models: ["claude-opus-4-8", "gemini-3"],
      aib_version: "1.1",
    });
  });

  it("does not treat primary/fallback keys outside models as model fields", () => {
    const raw = [
      "name: a",
      "version: 1",
      "description: d",
      "models:",
      "  primary: model-primary",
      "metadata:",
      "  primary: metadata-primary",
      "  fallback:",
      "    - metadata-fallback",
      "aib_version: 1.1",
    ].join("\n");
    const { data } = parseAgentYamlDocument(raw);
    expect(data.primary_model).toBe("model-primary");
    expect(data.fallback_models).toEqual([]);
  });
});

describe("patchAgentYamlDocument", () => {
  it("returns byte-identical raw when data is unchanged", () => {
    const doc = parseAgentYamlDocument(RICH_CRLF_NOEOL);
    const result = patchAgentYamlDocument(RICH_CRLF_NOEOL, doc.data);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.raw).toBe(RICH_CRLF_NOEOL);
  });

  it("patches top-level scalar while preserving comments and unknown blocks", () => {
    const doc = parseAgentYamlDocument(RICH);
    const result = patchAgentYamlDocument(RICH, { ...doc.data, name: "new-agent" });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.raw).toContain("name: new-agent # keep name comment");
    expect(result.raw).toContain("description: \"Old description # not comment\" # keep desc comment");
    expect(result.raw).toContain("memory:\n  sessions: sessions/");
    expect(result.raw).toContain("skills:\n  discovery: auto");
    expect(result.raw).toContain("custom_policy:\n  x: y");
  });

  it("patches quoted description without treating # inside quotes as comment", () => {
    const doc = parseAgentYamlDocument(RICH);
    const result = patchAgentYamlDocument(RICH, { ...doc.data, description: "New # value" });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.raw).toContain('description: "New # value" # keep desc comment');
    }
  });

  it("quotes changed unquoted scalars when needed", () => {
    const raw = [
      "name: a",
      "version: 1",
      "description: old",
      "models:",
      "  primary: p",
      "aib_version: 1.1",
    ].join("\n");
    const doc = parseAgentYamlDocument(raw);
    const result = patchAgentYamlDocument(raw, {
      ...doc.data,
      description: "New # value",
    });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.raw).toContain('description: "New # value"');
  });

  it("patches primary and fallback models while preserving model comments", () => {
    const doc = parseAgentYamlDocument(RICH);
    const result = patchAgentYamlDocument(RICH, {
      ...doc.data,
      primary_model: "gpt-6",
      fallback_models: ["claude-new"],
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.raw).toContain("  # model comment\n  primary: gpt-6 # keep primary comment\n  fallback:\n    - claude-new\n");
    expect(result.raw).not.toContain("gemini-3");
  });

  it("parses and preserves fallback item comments by index", () => {
    const raw = [
      "name: a",
      "version: 1",
      "description: d",
      "models:",
      "  primary: p",
      "  fallback:",
      "    - f1 # first fallback",
      "    - \"f2 # value\" # second fallback",
      "aib_version: 1.1",
    ].join("\n");
    const doc = parseAgentYamlDocument(raw);
    expect(doc.data.fallback_models).toEqual(["f1", "f2 # value"]);

    const result = patchAgentYamlDocument(raw, {
      ...doc.data,
      fallback_models: ["f1-new", "f2-new # value"],
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.raw).toContain("    - f1-new # first fallback");
    expect(result.raw).toContain('    - "f2-new # value" # second fallback');
  });

  it("inserts fallback block when missing and removes it when empty", () => {
    const raw = [
      "name: a",
      "version: 1",
      "description: d",
      "models:",
      "  primary: p",
      "aib_version: 1.1",
    ].join("\n");
    const doc = parseAgentYamlDocument(raw);
    const inserted = patchAgentYamlDocument(raw, { ...doc.data, fallback_models: ["f1", "f2"] });
    expect(inserted.ok).toBe(true);
    if (!inserted.ok) return;
    expect(inserted.raw).toContain("models:\n  primary: p\n  fallback:\n    - f1\n    - f2\naib_version");

    const doc2 = parseAgentYamlDocument(inserted.raw);
    const removed = patchAgentYamlDocument(inserted.raw, { ...doc2.data, fallback_models: [] });
    expect(removed.ok).toBe(true);
    if (removed.ok) expect(removed.raw).toContain("models:\n  primary: p\naib_version");
  });

  it("fails closed when changed top-level key is missing", () => {
    const raw = "version: 1\nmodels:\n  primary: p\n";
    const doc = parseAgentYamlDocument(raw);
    const result = patchAgentYamlDocument(raw, { ...doc.data, name: "x" });
    expect(result).toEqual({ ok: false, failure: { field: "name", reason: "key-not-found" } });
  });

  it("fails closed when duplicate top-level key exists", () => {
    const raw = "name: a\nname: b\nmodels:\n  primary: p\n";
    const doc = parseAgentYamlDocument(raw);
    const result = patchAgentYamlDocument(raw, { ...doc.data, name: "x" });
    expect(result).toEqual({ ok: false, failure: { field: "name", reason: "multiple-keys" } });
  });

  it("fails closed when models block is missing for model changes", () => {
    const raw = "name: a\nversion: 1\ndescription: d\naib_version: 1.1\n";
    const doc = parseAgentYamlDocument(raw);
    const result = patchAgentYamlDocument(raw, { ...doc.data, primary_model: "x" });
    expect(result).toEqual({ ok: false, failure: { field: "primary_model", reason: "models-not-found" } });
  });
});
