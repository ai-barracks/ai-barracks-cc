import { describe, expect, it } from "vitest";
import {
  parseGrowthDocument,
  patchGrowthDocument,
  type GrowthData,
} from "./growthDocument";

const RICH_FIXTURE_LF = [
  "<!-- AIB:OWNERSHIP — keep -->",
  "# Growth Protocol",
  "",
  "## Decision Table — 발견 즉시 기록 (CRITICAL)",
  "",
  "세션 **종료 시**가 아니라, **발견하는 즉시** 아래 표에 따라 기록한다.",
  "",
  "| 세션 중 이벤트 | 기록 위치 | 예시 |",
  "|---------------|-----------|------|",
  "| 새 사실/아키텍처 결정 발견 | `wiki/topics/` | 배포 순서 |",
  "| 사용자가 행동 교정 | `RULES.md` | 파일 수정 전 재읽기 |",
  "",
  "**NOT growth-worthy** — 기록하지 않을 것:",
  "- 단순 git commit",
  "- 일회성 사용자 선호",
  "",
  "## End-of-Session Audit",
  "",
  "세션 종료 전 누락을 점검한다.",
  "",
  "## Custom Section",
  "custom prose should stay",
  "```md",
  "| 세션 중 이벤트 | fake | table |",
  "**NOT growth-worthy** — fake inside code",
  "- fake not-growth item",
  "```",
].join("\n");

const RICH_FIXTURE_CRLF_NOEOL = RICH_FIXTURE_LF.replace(/\n/g, "\r\n");

function parsed(raw = RICH_FIXTURE_LF): GrowthData {
  return parseGrowthDocument(raw).data;
}

describe("parseGrowthDocument", () => {
  it("extracts decision table rows and not-growth bullets", () => {
    const data = parsed();
    expect(data.decision_table).toEqual([
      {
        event: "새 사실/아키텍처 결정 발견",
        location: "`wiki/topics/`",
        example: "배포 순서",
      },
      {
        event: "사용자가 행동 교정",
        location: "`RULES.md`",
        example: "파일 수정 전 재읽기",
      },
    ]);
    expect(data.not_growth_worthy).toEqual([
      "단순 git commit",
      "일회성 사용자 선호",
    ]);
  });
});

describe("patchGrowthDocument byte-identical roundtrip", () => {
  it("returns LF raw unchanged when data is unchanged", () => {
    const data = parsed(RICH_FIXTURE_LF);
    const result = patchGrowthDocument(RICH_FIXTURE_LF, data);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.raw).toBe(RICH_FIXTURE_LF);
  });

  it("returns CRLF/no-final-newline raw unchanged when data is unchanged", () => {
    const data = parsed(RICH_FIXTURE_CRLF_NOEOL);
    const result = patchGrowthDocument(RICH_FIXTURE_CRLF_NOEOL, data);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.raw).toBe(RICH_FIXTURE_CRLF_NOEOL);
  });
});

describe("patchGrowthDocument decision table", () => {
  it("patches only data rows and preserves audit/custom text", () => {
    const data = parsed();
    const next: GrowthData = {
      ...data,
      decision_table: [
        ...data.decision_table,
        { event: "오류/수정 검토", location: "`sessions/{id}.md`", example: "Retries" },
      ],
    };
    const result = patchGrowthDocument(RICH_FIXTURE_LF, next);
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.raw).toContain("| 세션 중 이벤트 | 기록 위치 | 예시 |\n|---------------|-----------|------|\n");
    expect(result.raw).toContain("| 오류/수정 검토 | `sessions/{id}.md` | Retries |\n");
    expect(result.raw).toContain("**NOT growth-worthy** — 기록하지 않을 것:\n- 단순 git commit\n- 일회성 사용자 선호\n");
    expect(result.raw).toContain("## End-of-Session Audit\n\n세션 종료 전 누락을 점검한다.");
    expect(result.raw).toContain("## Custom Section\ncustom prose should stay\n```md\n| 세션 중 이벤트 | fake | table |\n**NOT growth-worthy** — fake inside code\n- fake not-growth item\n```");
  });

  it("inserts rows into an empty table", () => {
    const raw = [
      "# Growth Protocol",
      "",
      "| 세션 중 이벤트 | 기록 위치 | 예시 |",
      "|---------------|-----------|------|",
      "",
      "**NOT growth-worthy** — 기록하지 않을 것:",
      "- skip",
      "",
    ].join("\n");
    const data = parseGrowthDocument(raw).data;
    expect(data.decision_table).toEqual([]);

    const result = patchGrowthDocument(raw, {
      ...data,
      decision_table: [{ event: "E", location: "L", example: "X" }],
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.raw).toContain("|---------------|-----------|------|\n| E | L | X |\n\n**NOT growth-worthy**");
    }
  });
});

describe("patchGrowthDocument not-growth list", () => {
  it("patches only the not-growth bullet run and preserves table/audit/custom text", () => {
    const data = parsed();
    const result = patchGrowthDocument(RICH_FIXTURE_LF, {
      ...data,
      not_growth_worthy: ["단순 git commit", "이미 wiki에 있는 반복"],
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.raw).toContain("- 단순 git commit\n- 이미 wiki에 있는 반복\n\n## End-of-Session Audit");
    expect(result.raw).toContain("| 새 사실/아키텍처 결정 발견 | `wiki/topics/` | 배포 순서 |\n");
    expect(result.raw).toContain("## Custom Section\ncustom prose should stay");
  });

  it("inserts first bullets after an empty NOT growth-worthy anchor", () => {
    const raw = [
      "# Growth Protocol",
      "",
      "| 세션 중 이벤트 | 기록 위치 | 예시 |",
      "|---------------|-----------|------|",
      "| E | L | X |",
      "",
      "**NOT growth-worthy** — 기록하지 않을 것:",
      "",
      "## End-of-Session Audit",
    ].join("\n");
    const data = parseGrowthDocument(raw).data;
    expect(data.not_growth_worthy).toEqual([]);

    const result = patchGrowthDocument(raw, {
      ...data,
      not_growth_worthy: ["skip one", "skip two"],
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.raw).toContain("**NOT growth-worthy** — 기록하지 않을 것:\n- skip one\n- skip two\n\n## End-of-Session Audit");
    }
  });
});

describe("patchGrowthDocument fail-closed behavior", () => {
  it("fails when decision table header is missing and table changes", () => {
    const raw = "# Growth\n\n**NOT growth-worthy** — 기록하지 않을 것:\n- x\n";
    const data = parseGrowthDocument(raw).data;
    const result = patchGrowthDocument(raw, {
      ...data,
      decision_table: [{ event: "E", location: "L", example: "X" }],
    });
    expect(result).toEqual({ ok: false, failure: { field: "decision_table", reason: "header-not-found" } });
  });

  it("fails on duplicate decision table headers", () => {
    const raw = [
      "| 세션 중 이벤트 | 기록 위치 | 예시 |",
      "|---|---|---|",
      "| A | B | C |",
      "",
      "| 세션 중 이벤트 | 기록 위치 | 예시 |",
      "|---|---|---|",
      "| D | E | F |",
      "",
    ].join("\n");
    const data = parseGrowthDocument(raw).data;
    const result = patchGrowthDocument(raw, {
      ...data,
      decision_table: [{ event: "X", location: "Y", example: "Z" }],
    });
    expect(result).toEqual({ ok: false, failure: { field: "decision_table", reason: "multiple-headers" } });
  });

  it("fails when decision table separator is missing", () => {
    const raw = [
      "| 세션 중 이벤트 | 기록 위치 | 예시 |",
      "| A | B | C |",
      "",
      "**NOT growth-worthy** — 기록하지 않을 것:",
      "- x",
    ].join("\n");
    const data = parseGrowthDocument(raw).data;
    const result = patchGrowthDocument(raw, {
      ...data,
      decision_table: [{ event: "X", location: "Y", example: "Z" }],
    });
    expect(result).toEqual({ ok: false, failure: { field: "decision_table", reason: "separator-not-found" } });
  });

  it("fails on duplicate NOT growth-worthy anchors", () => {
    const raw = [
      "| 세션 중 이벤트 | 기록 위치 | 예시 |",
      "|---|---|---|",
      "| A | B | C |",
      "",
      "**NOT growth-worthy** — 기록하지 않을 것:",
      "- x",
      "",
      "**NOT growth-worthy** — 기록하지 않을 것:",
      "- y",
    ].join("\n");
    const data = parseGrowthDocument(raw).data;
    const result = patchGrowthDocument(raw, {
      ...data,
      not_growth_worthy: ["z"],
    });
    expect(result).toEqual({ ok: false, failure: { field: "not_growth_worthy", reason: "multiple-anchors" } });
  });

  it("fails on multiple NOT growth-worthy bullet runs", () => {
    const raw = [
      "| 세션 중 이벤트 | 기록 위치 | 예시 |",
      "|---|---|---|",
      "| A | B | C |",
      "",
      "**NOT growth-worthy** — 기록하지 않을 것:",
      "- x",
      "",
      "prose interruption",
      "",
      "- y",
      "",
      "## End-of-Session Audit",
    ].join("\n");
    const data = parseGrowthDocument(raw).data;
    const result = patchGrowthDocument(raw, {
      ...data,
      not_growth_worthy: ["z"],
    });
    expect(result).toEqual({ ok: false, failure: { field: "not_growth_worthy", reason: "multiple-bullet-runs" } });
  });
});
