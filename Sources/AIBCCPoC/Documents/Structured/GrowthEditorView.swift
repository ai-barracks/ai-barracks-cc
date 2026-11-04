import SwiftUI

/// GROWTH.md as a table and a list (v1 GrowthFormEditor): Decision Table
/// rows and the NOT growth-worthy bullets. Everything else in the file
/// (audit rules, custom sections) is kept byte for byte.
struct GrowthEditorView: View {
    let original: String
    let onSave: (@escaping StructuredPatch) -> Void
    let onCancel: () -> Void
    @State private var data: GrowthData
    @State private var error: String?
    private let blocked: [String]

    init(original: String, onSave: @escaping (@escaping StructuredPatch) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        blocked = GrowthDocument.blocked(original).map(\.field.rawValue)
        _data = State(initialValue: GrowthDocument.parse(original))
    }

    var body: some View {
        StructuredEditorFrame(blocked: blocked, error: error, onCancel: onCancel, onSave: save) {
            Section {
                ForEach(data.decisionTable.indices, id: \.self) { index in
                    row(index)
                }
                Button("+ 행 추가") { data.decisionTable.append(DecisionRow()) }.buttonStyle(.borderless)
            } header: {
                Text("Decision Table (\(data.decisionTable.count)) — 세션 중 이벤트 · 기록 위치 · 예시")
            }
            BulletListSection(title: "NOT growth-worthy", placeholder: "기록하지 않을 것", items: $data.notGrowthWorthy)
        }
    }

    private func row(_ index: Int) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Grid(alignment: .leading, verticalSpacing: 4) {
                GridRow { caption("이벤트"); cell("세션 중 이벤트", index, \.event).fontWeight(.medium) }
                GridRow { caption("위치"); cell("기록 위치", index, \.location) }
                GridRow { caption("예시"); cell("예시", index, \.example).foregroundStyle(Tokens.textSecondary) }
            }
            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0)
            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                .disabled(index == data.decisionTable.count - 1)
            Button(role: .destructive) { data.decisionTable.remove(at: index) } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.borderless)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).gridColumnAlignment(.trailing)
    }

    private func cell(_ title: String, _ index: Int, _ key: WritableKeyPath<DecisionRow, String>) -> some View {
        TextField(title, text: Binding(get: { data.decisionTable.indices.contains(index) ? data.decisionTable[index][keyPath: key] : "" },
                                       set: { if data.decisionTable.indices.contains(index) { data.decisionTable[index][keyPath: key] = $0 } }),
                  prompt: Text(title), axis: .vertical)
            .labelsHidden()
            .lineLimit(1...3)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard data.decisionTable.indices.contains(target) else { return }
        data.decisionTable.swapAt(index, target)
    }

    private func save() {
        let rows = data.decisionTable
            .map { DecisionRow(event: clean($0.event), location: clean($0.location), example: clean($0.example)) }
            .filter { !($0.event.isEmpty && $0.location.isEmpty && $0.example.isEmpty) }
        // An unescaped "|" would split the cell when the row is read back
        // ("\|" is a literal pipe in a Markdown table and stays).
        if rows.contains(where: { [$0.event, $0.location, $0.example].contains { Regex.matches(#"(^|[^\\])\|"#, $0) } }) {
            error = "표의 칸에 | 를 쓰려면 \\| 로 적으세요."
            return
        }
        let next = GrowthData(decisionTable: rows, notGrowthWorthy: StructuredEditing.cleaned(data.notGrowthWorthy))
        let patch = StructuredEditing.patch(original: original, mine: next, parse: GrowthDocument.parse, merge: GrowthDocument.merge) { raw, data in
            GrowthDocument.patch(raw, to: data).mapError { StructuredEditing.ambiguous($0.field.rawValue, $0.reason) }
        }
        submit(patch)
    }

    private func clean(_ text: String) -> String {
        StructuredEditing.singleLine(text).trimmingCharacters(in: .whitespaces)
    }

    /// Checks the patch on the text the form was opened on, then hands it
    /// to the document view (which owns the conflict check).
    private func submit(_ patch: @escaping StructuredPatch) {
        if case let .failure(failure) = patch(original) {
            error = failure.message
            return
        }
        error = nil
        onSave(patch)
    }
}
