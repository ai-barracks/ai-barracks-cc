import Foundation

/// Maps docs/acceptance-criteria.md parent IDs to the sub-results that must
/// all pass. A parent is `fail` if any sub failed, `pass` only if every
/// required sub passed, otherwise `unverified` (missing or pending human
/// evidence). The self-test never upgrades a parent on partial coverage.
enum CriteriaCatalog {
    struct Criterion {
        let id: String
        let title: String
        let blocking: Bool
        let requires: [String]
        /// Extra evidence: a `fail` here fails the parent, but `unverified`
        /// never blocks it (e.g. synthetic IME when IMK is not reachable).
        var optional: [String] = []
    }

    static let criteria: [Criterion] = input + resize + selection + readability + stability + regression + markdown
        + persistence + reproductions + product

    private static let input: [Criterion] = [
        .init(id: "IN-01", title: "한글 조합 표시·확정 1회", blocking: true, requires: ["IN-01a", "IN-01-phys"], optional: ["IN-01-syn"]),
        .init(id: "IN-02", title: "조합 중 Backspace", blocking: true, requires: ["IN-02a", "IN-02-phys"]),
        .init(id: "IN-03", title: "한/영 전환 직후 첫 글자", blocking: true, requires: ["IN-03-phys"]),
        .init(id: "IN-04", title: "조합 중 pane 전환 오배달 0", blocking: true, requires: ["IN-04a", "IN-04-phys"]),
        .init(id: "IN-05", title: "스페이스 0x20 1바이트", blocking: true, requires: ["IN-05a"]),
        .init(id: "IN-06", title: "빠른 연속 타이핑(영·한 혼합)", blocking: true, requires: ["IN-06a", "IN-06-phys"]),
        .init(id: "IN-07", title: "붙여넣기 중복 0·원문 보존", blocking: true, requires: ["IN-07a", "IN-07b", "IN-07-phys"]),
        .init(id: "IN-08", title: "bracketed paste 종료 구분자 정책", blocking: true, requires: ["IN-08a"]),
        .init(id: "IN-09", title: "Ctrl+C → SIGINT", blocking: true, requires: ["IN-09a", "IN-09b", "IN-09c"]),
        .init(id: "IN-10", title: "Esc·Shift+Enter·Option·dead key·반복", blocking: true, requires: ["IN-10a", "IN-10-phys"]),
        .init(id: "IN-11", title: "앱 단축키가 PTY로 새지 않음", blocking: true, requires: ["IN-11a", "IN-11b", "IN-11c"]),
        .init(id: "IN-12", title: "후보창 위치", blocking: false, requires: ["IN-12-phys"]),
    ]

    private static let resize: [Criterion] = [
        .init(id: "RS-01", title: "창 연속 축소·확대", blocking: true, requires: ["RS-01a", "RS-01b"]),
        .init(id: "RS-02", title: "전체화면", blocking: true, requires: ["RS-02a", "RS-02b"]),
        .init(id: "RS-03", title: "split·패널 변경", blocking: true, requires: ["RS-03a", "RS-03b"]),
        .init(id: "RS-04", title: "폰트 크기 변경", blocking: true, requires: ["RS-04a", "RS-04b", "RS-04c"]),
        .init(id: "RS-05", title: "스크롤백 보존·프롬프트 reflow", blocking: true, requires: ["RS-05-phys"]),
        .init(id: "RS-06", title: "Claude Code TUI 잔해 레퍼런스 대비", blocking: true, requires: ["RS-06-cu"]),
        .init(id: "RS-07", title: "다른 해상도 모니터", blocking: false, requires: ["RS-07-phys"]),
        .init(id: "RS-08", title: "수렴 시간", blocking: false, requires: ["RS-08a"]),
    ]

    private static let selection: [Criterion] = [
        .init(id: "SC-01", title: "드래그 선택 → ⌘C", blocking: true, requires: ["SC-01a"]),
        .init(id: "SC-02", title: "더블·트리플클릭", blocking: true, requires: ["SC-02a", "SC-02b"]),
        .init(id: "SC-03", title: "Option 사각 선택", blocking: true, requires: ["SC-03a"]),
        .init(id: "SC-04", title: "soft-wrap 한 줄·줄끝 공백", blocking: true, requires: ["SC-04a", "SC-04b"]),
        .init(id: "SC-05", title: "한글·이모지·줄끝 wide char", blocking: true, requires: ["SC-05a", "SC-05b", "SC-05c"]),
        .init(id: "SC-06", title: "TUI 마우스 점유 중 Shift+드래그", blocking: true, requires: ["SC-06a"]),
        .init(id: "SC-07", title: "스크롤하며 선택 확장", blocking: true, requires: ["SC-07-phys"]),
        .init(id: "SC-08", title: "복사 후 입력 유지", blocking: true, requires: ["SC-08a"]),
    ]

    private static let readability: [Criterion] = [
        .init(id: "RD-01", title: "한글 2칸 정렬·폴백 기준선", blocking: true, requires: ["RD-01-phys"]),
        .init(id: "RD-02", title: "다크/라이트 대비", blocking: true, requires: ["RD-02-phys"]),
        .init(id: "RD-03", title: "폰트·테마 설정", blocking: false, requires: ["RD-03-phys"]),
    ]

    private static let stability: [Criterion] = [
        .init(id: "ST-01", title: "4분할 핵심 항목", blocking: true, requires: ["ST-01a", "ST-01b", "ST-01c"]),
        .init(id: "ST-02", title: "대량 출력 중 입력 지연 p95", blocking: true, requires: ["ST-02a", "ST-02b", "ST-02-baseline"], optional: ["ST-02c"]),
        .init(id: "ST-03", title: "대량 출력 중 최장 정지", blocking: false, requires: ["ST-03-baseline"]),
        .init(id: "ST-04", title: "셸·앱 종료 시 프로세스 정리", blocking: true, requires: ["ST-04a", "ST-04-phys"]),
        .init(id: "ST-05", title: "OSC 알림·bell 수신", blocking: false, requires: ["ST-05-phys"]),
    ]

    private static let regression: [Criterion] = [
        .init(id: "RG-01", title: "한글 조합 누락·분리", blocking: true, requires: ["IN-01a", "IN-02a", "IN-01-phys"]),
        .init(id: "RG-02", title: "붙여넣기 중복 입력", blocking: true, requires: ["IN-07a", "IN-07b"]),
        .init(id: "RG-03", title: "스페이스 20+c2a0 이중 송신", blocking: true, requires: ["IN-05a", "IN-01a"]),
        .init(id: "RG-04", title: "리사이즈 마지막 행·열 잘림", blocking: true, requires: ["RS-01a", "RS-01b", "RS-04a"]),
    ]

    private static let markdown: [Criterion] = [
        .init(id: "MD-01", title: "최근 .md 목록", blocking: true, requires: ["MD-01a"]),
        .init(id: "MD-02", title: "GFM 렌더링·실패 시 원문", blocking: true, requires: ["MD-02-phys"]),
        .init(id: "MD-03", title: "자동 새로고침·위치 유지", blocking: true, requires: ["MD-03a", "MD-03-phys"]),
        .init(id: "MD-04", title: "뷰어 → 터미널 첫 글자", blocking: true, requires: ["MD-04a", "MD-04b"]),
        .init(id: "MD-05", title: "스크립트·외부 리소스 차단", blocking: true, requires: ["MD-05-review"]),
        .init(id: "MD-06", title: "고정 뷰어와 분리", blocking: false, requires: ["MD-01a"]),
        .init(id: "MD-07", title: "Mermaid", blocking: false, requires: ["MD-07-phys"]),
        .init(id: "WS-01", title: "배럭 선택·터미널·산출물 맥락 일치", blocking: true, requires: ["WS-01a"]),
        .init(id: "PK-01", title: "배포 앱이 자체 리소스로 동작(빌드 경로 비의존)", blocking: true,
              requires: ["PK-01a", "PK-01b"]),
    ]

    /// Spike (known issue #4), not a Go/No-go gate: two app launches via
    /// scripts/run-persist-test.sh with the daemon backend.
    private static let persistence: [Criterion] = [
        .init(id: "PS-01", title: "앱 종료 후 세션 생존·재부착", blocking: false,
              requires: ["PS-01a", "PS-01b", "PS-01c", "PS-01d", "PS-01e"]),
        .init(id: "PS-02", title: "재부착 실패·데몬 종료 복구", blocking: false, requires: ["PS-02a", "PS-02b", "PS-02c"]),
    ]

    /// v2 product logic (not Go/No-go gates).
    private static let product: [Criterion] = [
        .init(id: "LV-01", title: "liveness 접기·sidecar 읽기 = aib 규칙", blocking: false, requires: ["LV-01a", "LV-01b", "LV-01c"]),
        .init(id: "MD-08", title: "문서 표시에서 aib 메타데이터 주석 숨김", blocking: false, requires: ["MD-08a"]),
        .init(id: "AG-01", title: "⌘N 에이전트 시작(aib start)", blocking: false, requires: ["AG-01a", "AG-01b", "AG-01c"]),
        .init(id: "AT-01", title: "⌘⇧A 주의 항목 이동·done 확인", blocking: false, requires: ["AT-01a", "AT-01b", "AT-01c"]),
        .init(id: "SK-01", title: "Skills·Council 목적지", blocking: false, requires: ["SK-01a"]),
        .init(id: "SR-01", title: "세션 기록·봉인·Continue(v1 패리티 B1~B3)", blocking: false,
              requires: ["SR-01a", "SR-01b", "SR-01c", "SR-01d"]),
        .init(id: "SR-02", title: "⌘K 명령·통합 검색(v1 패리티 G1)", blocking: false, requires: ["SR-02a", "PL-01a"]),
        .init(id: "HM-01", title: "Health 감시·알림·자동 새로고침(v1 패리티 A3·A5·H4·C8)", blocking: false,
              requires: ["HM-01a", "HM-01b", "NC-01a", "AR-01a", "RG-02a"]),
        .init(id: "TT-01", title: "터미널 관리·Quick Commands·내보내기·설정(v1 패리티 C2~C6·B4·H3)", blocking: false,
              requires: ["TT-01a", "TT-01b", "SE-01a"]),
        .init(id: "PS-03", title: "복원 실패 시 세션 보존", blocking: false, requires: ["PS-03a"]),
        .init(id: "PS-04", title: "replay 입력 경계·종료 출력 보관", blocking: false, requires: ["PS-04a", "PS-04b"]),
        .init(id: "PS-05", title: "입력 거부는 종료 아님·분리 중 종료 세션 보관", blocking: false, requires: ["PS-05a", "PS-05b", "PS-05c"]),
        .init(id: "R6-01", title: "Codex r6 회귀", blocking: false, requires: ["R6-01a", "R6-01b", "R6-01c"]),
        .init(id: "LY-01", title: "레이아웃 최소 크기(최소 창에서 충돌·겹침 없음)", blocking: false, requires: ["LY-01a"]),
        .init(id: "LY-02", title: "Outputs가 작업면을 잠식하지 않음", blocking: false, requires: ["LY-02a", "LY-02b"]),
        .init(id: "PN-01", title: "가득 찬 그리드: 빈 셸 자리 재사용·거부 시 알림", blocking: false, requires: ["PN-01a"]),
        .init(id: "R7-01", title: "Codex r7 회귀", blocking: false, requires: ["R7-01a", "R7-01b", "R7-01c", "R7-01d"]),
        .init(id: "NV-01", title: "편집 중 이동 확인", blocking: false, requires: ["NV-01a", "NV-01b", "NV-01c"]),
        .init(id: "R5-01", title: "Codex r5 전역 상태 회귀", blocking: false, requires: ["R5-01a"]),
        .init(id: "V1-01", title: "v1 설정 가져오기", blocking: false, requires: ["V1-01a"]),
        .init(id: "AC-01", title: "예약 활성화(v1 activation)", blocking: false, requires: ["AC-01a", "AC-01b", "AC-01c"]),
        .init(id: "AC-02", title: "예약 활성화 안전 UX(켜기 전 확인·OFF 경로·상태 갱신)", blocking: false, requires: ["AC-02a"]),
        .init(id: "PR-01", title: "Provider/Model 프로필(v1 providers)", blocking: false, requires: ["PR-01a", "PR-01b"]),
        .init(id: "SB-01", title: "터미널 출력 보관(v1 scrollback archive)", blocking: false, requires: ["SB-01a", "SB-01b"]),
        .init(id: "OV-01", title: "배럭 개요(v1 Overview)", blocking: false, requires: ["OV-01a"]),
        .init(id: "OV-02", title: "Info 규칙 수가 RULES.md 전체와 일치", blocking: false, requires: ["OV-02a"]),
        .init(id: "BA-01", title: "배럭 추가·제거·새로 고침 = v1(aib init / barracks remove / refresh)", blocking: false, requires: ["BA-01a"]),
        .init(id: "GT-01", title: "Git 상태·커밋·push = v1 + 모노레포 커밋 격리", blocking: false, requires: ["GT-01a", "GT-01b"]),
        .init(id: "SK-02", title: "Skills CRUD = v1(폼·이름 변경·삭제·경로 안전)", blocking: false, requires: ["SK-02a", "SK-02b", "SK-02c", "SK-02d"]),
        .init(id: "DC-01", title: "구조화 편집기 문서 모델 = v1 테스트 케이스", blocking: false,
              requires: ["DP-01a", "DP-01b", "RU-01a", "RU-01b", "SD-01a", "SD-01b", "GR-01a", "GR-01b", "YM-01a", "YM-01b", "SM-01a", "UX-01a", "CR-05a"]),
        .init(id: "PO-01", title: "자식 프로세스 출력 읽기(파이프 교착 없음)", blocking: false, requires: ["PO-01a", "PO-01b", "PO-01c"]),
        .init(id: "ED-01", title: "규칙 문서 편집(허용 범위·충돌 감지)", blocking: false, requires: ["ED-01a", "ED-01b"]),
        .init(id: "DS-01", title: "목적지 왕복 후 터미널 보존", blocking: false, requires: ["DS-01a"]),
        .init(id: "DB-01", title: "세션 유지 기본값(데몬)·테스트 격리", blocking: false, requires: ["DB-01a"]),
        .init(id: "MT-01", title: "정비 큐(aib 점검 → 판단 → pane 실행)", blocking: false, requires: ["MT-01a", "MT-01b", "MT-01c", "MT-01d"]),
    ]

    /// Reproduction suites for observations that never became bugs (run
    /// explicitly: repro10, repro-r5); kept as regression checks.
    private static let reproductions: [Criterion] = [
        .init(id: "RP-10", title: "pane 교체 직후 첫 키 유실(알려진 이슈 #10)", blocking: false,
              requires: ["RP-10a", "RP-10b", "RP-10c", "RP-10d"]),
        .init(id: "RP-R5", title: "창 상태 변화 후 화면 갱신(Codex 실행 리뷰 R5)", blocking: false,
              requires: ["RP-R5a", "RP-R5b"]),
    ]

    /// Every sub-ID that no automated suite produces: listed as `unverified`
    /// with the method that can verify it.
    static func pendingSubResults(excluding measured: Set<String>) -> [TestResult] {
        let start = ContinuousClock.now
        let required = Set(criteria.flatMap(\.requires) + criteria.flatMap(\.optional))
        return required.subtracting(measured).sorted().map { id in
            .make(id, "자동화 범위 밖", status: .unverified,
                  layer: id.hasPrefix("IN-") && id.hasSuffix("-phys") ? .physicalKeyboardIME : nil,
                  evidence: ["method": method(for: id)], startedAt: start)
        }
    }

    static func aggregate(_ subs: [TestResult]) -> [TestResult] {
        let byID = Dictionary(subs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let start = ContinuousClock.now
        return criteria.map { criterion in
            let found = criterion.requires.compactMap { byID[$0] }
            let optionalFailed = criterion.optional.compactMap { byID[$0] }.contains { $0.status == .fail }
            let status: TestStatus = optionalFailed || found.contains { $0.status == .fail } ? .fail
                : found.count == criterion.requires.count && found.allSatisfy({ $0.status == .pass }) ? .pass
                : .unverified
            return .make(criterion.id, criterion.title, status: status, cause: .unknown,
                         evidence: ["requires": criterion.requires.joined(separator: ","),
                                    "optional": criterion.optional.joined(separator: ","),
                                    "blocking": "\(criterion.blocking)"],
                         startedAt: start)
        }
    }

    private static func method(for id: String) -> String {
        if id.hasSuffix("-cu") { return "codex-computer-use" }
        if id.hasSuffix("-baseline") { return "measure v1.6.1 baseline first" }
        if id.hasSuffix("-review") { return "code review" }
        if id.hasPrefix("PS-") { return "scripts/run-persist-test.sh" }
        if id == "PK-01b" { return "scripts/verify-standalone.sh" }
        if id.hasPrefix("RP-10") { return "--selftest-only=repro10" }
        if id.hasPrefix("RP-R5") { return "--selftest-only=repro-r5 (capture-watcher)" }
        return "human"
    }
}
