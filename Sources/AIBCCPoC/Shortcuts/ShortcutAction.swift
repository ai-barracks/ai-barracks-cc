import Carbon.HIToolbox

/// What a shortcut can do (2026-11-24, user: shortcuts for what is handy,
/// each one settable). Defaults keep the keys earlier builds had.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case palette, newAgent, newTerminal, wrapUp, closeTerminal, nextAttention, acknowledgeFinished, council
    case focusNextPane, focusPreviousPane, layoutSingle, layoutDouble, layoutTwoRows, layoutQuad
    case toggleOutputs, toggleAgentList
    case goBarrack, goAgents, goHistory, goFiles, goRules, goWiki, goSkills, goCouncil, goGit
    case nextBarrack, previousBarrack

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case agents = "에이전트", panes = "칸·레이아웃", navigation = "이동"
        var id: String { rawValue }
    }

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .palette, .newAgent, .newTerminal, .wrapUp, .closeTerminal, .nextAttention, .acknowledgeFinished, .council: .agents
        case .focusNextPane, .focusPreviousPane, .layoutSingle, .layoutDouble, .layoutTwoRows, .layoutQuad,
             .toggleOutputs, .toggleAgentList: .panes
        default: .navigation
        }
    }

    var title: String {
        if let destination { return "\(destination.label) 화면으로" }
        if let layout { return layout.title }
        switch self {
        case .palette: return "명령·검색"
        case .newAgent: return "새 에이전트…"
        case .newTerminal: return "새 터미널(셸)"
        case .wrapUp: return "정리하고 닫기"
        case .closeTerminal: return "터미널 닫기…"
        case .nextAttention: return "다음 주의 항목으로"
        case .acknowledgeFinished: return "완료한 세션 모두 확인"
        case .council: return "Council 시작…"
        case .focusNextPane: return "다음 칸으로"
        case .focusPreviousPane: return "이전 칸으로"
        case .toggleOutputs: return "Outputs 패널 보기/숨기기"
        case .toggleAgentList: return "에이전트 목록 보기/숨기기"
        case .nextBarrack: return "다음 배럭"
        case .previousBarrack: return "이전 배럭"
        default: return rawValue
        }
    }

    var destination: Destination? {
        switch self {
        case .goBarrack: .barrack
        case .goAgents: .sessions
        case .goHistory: .history
        case .goFiles: .files
        case .goRules: .rules
        case .goWiki: .wiki
        case .goSkills: .skills
        case .goCouncil: .council
        case .goGit: .git
        default: nil
        }
    }

    var layout: PaneLayout? {
        switch self {
        case .layoutSingle: .single
        case .layoutDouble: .double
        case .layoutTwoRows: .twoRows
        case .layoutQuad: .quad
        default: nil
        }
    }

    /// nil: no key until the user sets one.
    var defaultChord: KeyChord? {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        if let destination, let index = Destination.allCases.firstIndex(of: destination), index < digits.count {
            return KeyChord(digits[index], .command)
        }
        if let layout, let index = PaneLayout.allCases.firstIndex(of: layout) {
            return KeyChord(digits[index], [.command, .option])
        }
        switch self {
        case .palette: return KeyChord(kVK_ANSI_K, .command)
        case .newAgent: return KeyChord(kVK_ANSI_N, .command)
        case .newTerminal: return KeyChord(kVK_ANSI_T, .command)
        case .wrapUp: return KeyChord(kVK_ANSI_W, [.command, .shift])
        case .nextAttention: return KeyChord(kVK_ANSI_A, [.command, .shift])
        case .council: return KeyChord(kVK_ANSI_C, [.command, .shift])
        case .focusNextPane: return KeyChord(kVK_ANSI_RightBracket, .command)
        case .focusPreviousPane: return KeyChord(kVK_ANSI_LeftBracket, .command)
        case .toggleOutputs: return KeyChord(kVK_ANSI_I, [.command, .option])
        case .toggleAgentList: return KeyChord(kVK_ANSI_L, [.command, .option])
        case .nextBarrack: return KeyChord(kVK_DownArrow, [.command, .option])
        case .previousBarrack: return KeyChord(kVK_UpArrow, [.command, .option])
        default: return nil
        }
    }
}
