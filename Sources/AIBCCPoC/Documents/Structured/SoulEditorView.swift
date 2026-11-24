import SwiftUI

/// SOUL.md as a form (v1 SoulFormEditor): the name line and the four
/// identity lists. Saving goes through `SoulDocument.patch` (fail closed).
struct SoulEditorView: View {
    let original: String
    let onSave: (@escaping StructuredPatch) -> Void
    let onCancel: () -> Void
    @State private var data: SoulData
    @State private var error: String?
    private let blocked: [String]

    init(original: String, onSave: @escaping (@escaping StructuredPatch) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        blocked = SoulDocument.blocked(original).map(\.field.rawValue)
        _data = State(initialValue: SoulDocument.parse(original))
    }

    var body: some View {
        StructuredEditorFrame(blocked: blocked, error: error, onCancel: onCancel, onSave: save) {
            Section("Name") { TextField("Name", text: $data.name, prompt: Text("에이전트 이름")).labelsHidden() }
            BulletListSection(title: "Expertise", placeholder: "전문 분야", items: $data.expertise)
            BulletListSection(title: "Personality", placeholder: "성격·톤", items: $data.personality)
            BulletListSection(title: "Core Values", placeholder: "핵심 가치", items: $data.coreValues)
            BulletListSection(title: "Constraints", placeholder: "제약", items: $data.constraints)
        }
    }

    private func save() {
        let cleaned = SoulData(name: StructuredEditing.singleLine(data.name).trimmingCharacters(in: .whitespaces),
                               expertise: StructuredEditing.cleaned(data.expertise),
                               personality: StructuredEditing.cleaned(data.personality),
                               coreValues: StructuredEditing.cleaned(data.coreValues),
                               constraints: StructuredEditing.cleaned(data.constraints))
        let patch = StructuredEditing.patch(original: original, mine: cleaned, parse: SoulDocument.parse, merge: SoulDocument.merge) { raw, data in
            SoulDocument.patch(raw, to: data).mapError { StructuredEditing.ambiguous($0.field.rawValue, $0.reason) }
        }
        submit(patch)
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
