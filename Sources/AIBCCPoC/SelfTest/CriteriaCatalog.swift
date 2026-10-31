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

    private static let input: [Criterion] = [
        .init(id: "IN-01", title: "한글 조합 표시·확정 1회", blocking: true, requires: ["IN-01a", "IN-01-phys"], optional: ["IN-01-syn"]),
        .init(id: "IN-02", title: "조합 중 Backspace", blocking: true, requires: ["IN-02a", "IN-02-phys"]),
        .init(id: "IN-03", title: "한/영 전환 직후 첫 글자", blocking: true, requires: ["IN-03-phys"]),
        .init(id: "IN-04", title: "조합 중 pane 전환 오배달 0", blocking: true, requires: ["IN-04a", "IN-04-phys"]),
        .init(id: "IN-05", title: "스페이스 0x20 1바이트", blocking: true, requires: ["IN-05a"]),
        .init(id: "IN-06", title: "빠른 연속 타이핑(영·한 혼합)", blocking: true, requires: ["IN-06a", "IN-06-phys"]),
        .init(id: "IN-07", title: "붙여넣기 중복 0·원문 보존", blocking: true, requires: ["IN-07a", "IN-07b", "IN-07-phys"]),
        .init(id: "IN-08", title: "bracketed paste 종료 구분자 정책", blocking: true, requires: ["IN-08a"]),
        .init(id: "IN-09", title: "Ctrl+C → SIGINT", blocking: true, requires: ["IN-09a"]),
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
        .init(id: "ST-01", title: "4분할 핵심 항목", blocking: true, requires: ["ST-01a", "ST-01b"]),
        .init(id: "ST-02", title: "대량 출력 중 입력 지연 p95", blocking: true, requires: ["ST-02-baseline"]),
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
                                    "blocking": "\(criterion.blocking)"],
                         startedAt: start)
        }
    }

    private static func method(for id: String) -> String {
        if id == "ST-01b" { return "not automated yet: rerun IN/SC core in 4-split" }
        if id == "MD-04b" { return "not automated yet: click+scroll viewer, then return" }
        if id.hasSuffix("-cu") { return "codex-computer-use" }
        if id.hasSuffix("-baseline") { return "measure v1.6.1 baseline first" }
        if id.hasSuffix("-review") { return "code review" }
        return "human"
    }
}
