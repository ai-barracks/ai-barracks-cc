import { describe, expect, it } from "vitest";
import { DEFAULT_ACTIVATION, formatKstSlot, hasSelectedCli } from "./activationSchedule";

describe("activation schedule", () => {
  it("is OFF by default", () => { expect(DEFAULT_ACTIVATION.enabled).toBe(false); });
  it("requires at least one selected provider", () => {
    expect(hasSelectedCli({ enabled: true, claude: false, codex: false })).toBe(false);
    expect(hasSelectedCli({ enabled: false, claude: true, codex: false })).toBe(true);
    expect(hasSelectedCli({ enabled: true, claude: false, codex: true })).toBe(true);
  });
  it("formats in KST regardless of host timezone", () => { expect(formatKstSlot("2026-09-30T21:00:00Z")).toBe("01/10, 06:00 KST"); });
  it("handles malformed history defensively", () => { expect(formatKstSlot("bad date")).toBe("Unknown"); });
});
