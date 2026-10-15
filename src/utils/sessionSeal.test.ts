import { describe, expect, it } from "vitest";
import { sealWarning } from "./sessionSeal";

describe("sealWarning", () => {
  it("warns about a modified session with the approval command for that id", () => {
    const w = sealWarning("modified", "claude-20261014-1000");
    expect(w?.title).toBe("종료 후 변경됨");
    expect(w?.message).toContain("aib sessions seal claude-20261014-1000");
  });

  it("points an unverifiable seal at aib sessions verify", () => {
    const w = sealWarning("invalid", "codex-1");
    expect(w?.title).toBe("봉인 확인 불가");
    expect(w?.message).toContain("aib sessions verify");
  });

  it("stays silent for intact and unsealed sessions", () => {
    expect(sealWarning("intact", "x")).toBeNull();
    expect(sealWarning("unsealed", "x")).toBeNull();
  });
});
