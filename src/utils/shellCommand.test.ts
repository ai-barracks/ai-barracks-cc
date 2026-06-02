import { describe, expect, it } from "vitest";
import { aibCommand, printfLine, shellJoin, shellQuote } from "./shellCommand";

describe("shell command helpers", () => {
  it("quotes empty strings, spaces, and single quotes", () => {
    expect(shellQuote("")).toBe("''");
    expect(shellQuote("/tmp/has space")).toBe("'/tmp/has space'");
    expect(shellQuote("/tmp/o'clock")).toBe("'/tmp/o'\\''clock'");
  });

  it("shellJoin quotes every argument", () => {
    expect(shellJoin(["/usr/local/bin/aib", "sync", "/tmp/o'clock"])).toBe(
      "'/usr/local/bin/aib' 'sync' '/tmp/o'\\''clock'"
    );
  });

  it("builds aib commands and printf lines safely", () => {
    expect(aibCommand("aib", ["council", "topic with 'quote'"])).toBe(
      "'aib' 'council' 'topic with '\\''quote'\\'''"
    );
    expect(printfLine("\n=== x'y ===")).toBe(
      "printf '%s\\n' '\n=== x'\\''y ==='"
    );
  });
});
