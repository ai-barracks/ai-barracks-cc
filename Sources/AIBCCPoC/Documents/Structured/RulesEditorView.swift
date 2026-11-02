import SwiftUI

/// RULES.md as three lists (v1 RulesEditor): add, edit, delete, reorder.
/// Saving patches only the lists that changed, byte-preserving the rest,
/// and refuses a file whose shape is ambiguous (the raw editor remains).
struct RulesEditorView: View {
    let original: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var data: RulesData
    @State private var error: String?

    init(original: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        _data = State(initialValue: RulesDocument.parse(original))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let error { Text(error).font(Tokens.Font.meta).foregroundStyle(Tokens.red).lineLimit(2) }
                Spacer()
                Button("취소", action: onCancel)
                Button("저장") { save() }.keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.bottom, Tokens.Spacing.s)
            Form {
                list(.mustAlways, binding: $data.mustAlways)
                list(.mustNever, binding: $data.mustNever)
                list(.learned, binding: $data.learned)
            }
            .formStyle(.grouped)
        }
    }

    private func list(_ field: RulesDocument.Field, binding items: Binding<[String]>) -> some View {
        Section {
            ForEach(items.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: Tokens.Spacing.s) {
                    TextField("규칙", text: Binding(get: { items.wrappedValue[index] },
                                                   set: { items.wrappedValue[index] = $0 }), axis: .vertical)
                        .lineLimit(1...4)
                    Button { move(items, index, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                    Button { move(items, index, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == items.wrappedValue.count - 1)
                    Button(role: .destructive) { items.wrappedValue.remove(at: index) } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
            }
            Button("+ 규칙 추가") { items.wrappedValue.append("") }.buttonStyle(.borderless)
        } header: {
            Text("\(field.rawValue) (\(items.wrappedValue.count))")
        }
    }

    private func move(_ items: Binding<[String]>, _ index: Int, by offset: Int) {
        let target = index + offset
        guard items.wrappedValue.indices.contains(target) else { return }
        items.wrappedValue.swapAt(index, target)
    }

    private func save() {
        // Blank rows are dropped rather than written as empty bullets.
        let cleaned = RulesData(mustAlways: data.mustAlways.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                                mustNever: data.mustNever.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                                learned: data.learned.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        switch RulesDocument.patch(original, to: cleaned) {
        case let .success(raw): onSave(raw)
        case let .failure(failure):
            error = "\(failure.field.rawValue) 섹션 형식이 모호해 목록으로 저장할 수 없습니다(\(failure.reason)). 원문 편집을 쓰세요."
        }
    }
}
