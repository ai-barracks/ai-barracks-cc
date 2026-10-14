import type { SealStatus } from "../types";

export interface SealWarning {
  title: string;
  message: string;
}

// Session files are RECORD (no edits after end) and aib seals them at SessionEnd.
// Only states the user should act on produce a warning; unsealed (legacy or still
// active) and intact sessions stay silent. Approval stays a deliberate CLI step.
export function sealWarning(status: SealStatus, sessionId: string): SealWarning | null {
  switch (status) {
    case "modified":
      return {
        title: "종료 후 변경됨",
        message: `봉인된 내용과 현재 파일이 다릅니다. 의도한 변경이면 터미널에서 aib sessions seal ${sessionId} 로 승인하세요.`,
      };
    case "invalid":
      return {
        title: "봉인 확인 불가",
        message: "봉인 파일을 검증할 수 없습니다. 터미널에서 aib sessions verify 로 확인하세요.",
      };
    default:
      return null;
  }
}
