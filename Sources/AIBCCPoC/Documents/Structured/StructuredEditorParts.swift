import SwiftUI

/// Shared chrome of the structured editors: error line, cancel and save
/// (⌘S) above a grouped form.
struct StructuredEditorFrame<Content: View>: View {
    /// Parts of this file the form cannot save, known before editing.
    var blocked: [String] = []
    let error: String?
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let error { Text(error).font(Tokens.Font.meta).foregroundStyle(Tokens.red).lineLimit(3) }
                Spacer()
                Button("취소", action: onCancel)
                Button("저장", action: onSave).keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.bottom, Tokens.Spacing.s)
            if !blocked.isEmpty {
                Label("이 파일의 \(blocked.joined(separator: ", ")) 섹션은 형식이 표준과 달라 폼으로 저장할 수 없습니다. 바꾸려면 원문 편집을 쓰세요.",
                      systemImage: "exclamationmark.triangle")
                    .font(Tokens.Font.meta)
                    .foregroundStyle(Tokens.orange)
                    .padding(.horizontal, Tokens.Spacing.m)
                    .padding(.bottom, Tokens.Spacing.s)
            }
            Form { content() }.formStyle(.grouped)
        }
    }
}

/// One managed bullet list: edit in place, reorder, delete, add.
struct BulletListSection: View {
    let title: String
    let placeholder: String
    @Binding var items: [String]

    var body: some View {
        Section {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: Tokens.Spacing.s) {
                    TextField(placeholder, text: Binding(get: { items.indices.contains(index) ? items[index] : "" },
                                                         set: { if items.indices.contains(index) { items[index] = $0 } }),
                              prompt: Text(placeholder), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...6)
                    Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == items.count - 1)
                    Button(role: .destructive) { items.remove(at: index) } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
            }
            Button("+ \(placeholder) 추가") { items.append("") }.buttonStyle(.borderless)
        } header: {
            Text("\(title) (\(items.count))")
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }
}

/// The form's changes as a function of a file text, so they can be
/// applied to the text the form was opened on or, after a conflict, to the
/// file as it is now (an agent may have appended to another section).
typealias StructuredPatch = (String) -> Result<String, StructuredFailure>

/// Why the form's changes could not be written, as shown to the user.
struct StructuredFailure: Error, Equatable {
    let message: String
}

enum StructuredEditing {
    /// Section-level three-way merge: a section only the user changed takes
    /// the user's version, one only the file changed keeps the file's, and
    /// the same section changed differently on both sides cannot be merged.
    static func pick<T: Equatable>(_ base: T, _ mine: T, _ theirs: T) -> T? {
        if mine == base { return theirs }
        return theirs == base || theirs == mine ? mine : nil
    }

    static let bothChanged = StructuredFailure(message: "같은 섹션을 다른 곳도 고쳐 내 변경을 다시 적용할 수 없습니다. 다시 불러온 뒤 편집하세요.")

    /// The patch for one editor: merge onto the given text, then patch it.
    static func patch<Data>(original: String, mine: Data, parse: @escaping (String) -> Data,
                            merge: @escaping (Data, Data, Data) -> Data?,
                            apply: @escaping (String, Data) -> Result<String, StructuredFailure>) -> StructuredPatch {
        let base = parse(original)
        return { raw in
            guard let merged = merge(base, mine, parse(raw)) else { return .failure(bothChanged) }
            return apply(raw, merged)
        }
    }

    /// Blank rows are dropped rather than written as empty bullets, and a
    /// line break typed into a row becomes a space (one bullet = one line).
    static func cleaned(_ items: [String]) -> [String] {
        items.map(singleLine).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    static func ambiguous(_ section: String, _ reason: some Error) -> StructuredFailure {
        StructuredFailure(message: "\(section) 섹션 형식이 모호해 폼으로 저장할 수 없습니다(\(reason)). 원문 편집을 쓰세요.")
    }
}

/// Which structured editor a barrack file has, if any (v1 Rules tab forms).
enum StructuredKind {
    case rules, soul, growth, agentYaml

    init?(file: URL) {
        switch file.lastPathComponent {
        case "RULES.md": self = .rules
        case "SOUL.md": self = .soul
        case "GROWTH.md": self = .growth
        case "agent.yaml": self = .agentYaml
        default: return nil
        }
    }

    var editLabel: String {
        switch self {
        case .rules: "목록 편집"
        case .soul, .agentYaml: "폼 편집"
        case .growth: "표 편집"
        }
    }

    @MainActor @ViewBuilder
    func editor(original: String, onSave: @escaping (@escaping StructuredPatch) -> Void, onCancel: @escaping () -> Void) -> some View {
        switch self {
        case .rules: RulesEditorView(original: original, onSave: onSave, onCancel: onCancel)
        case .soul: SoulEditorView(original: original, onSave: onSave, onCancel: onCancel)
        case .growth: GrowthEditorView(original: original, onSave: onSave, onCancel: onCancel)
        case .agentYaml: AgentYamlEditorView(original: original, onSave: onSave, onCancel: onCancel)
        }
    }
}
