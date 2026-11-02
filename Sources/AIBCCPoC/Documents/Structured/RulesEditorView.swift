import SwiftUI

/// RULES.md as three lists (v1 RulesEditor): add, edit, delete, reorder.
/// Saving patches only the lists that changed, byte-preserving the rest,
/// and refuses a file whose shape is ambiguous (the raw editor remains).
struct RulesEditorView: View {
    let original: String
    let onSave: (@escaping StructuredPatch) -> Void
    let onCancel: () -> Void
    @State private var data: RulesData
    @State private var error: String?
    private let blocked: [String]

    init(original: String, onSave: @escaping (@escaping StructuredPatch) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        blocked = RulesDocument.blocked(original).map(\.field.rawValue)
        _data = State(initialValue: RulesDocument.parse(original))
    }

    var body: some View {
        StructuredEditorFrame(blocked: blocked, error: error, onCancel: onCancel, onSave: save) {
            BulletListSection(title: RulesDocument.Field.mustAlways.rawValue, placeholder: "규칙", items: $data.mustAlways)
            BulletListSection(title: RulesDocument.Field.mustNever.rawValue, placeholder: "규칙", items: $data.mustNever)
            BulletListSection(title: RulesDocument.Field.learned.rawValue, placeholder: "규칙", items: $data.learned)
        }
    }

    private func save() {
        let cleaned = RulesData(mustAlways: StructuredEditing.cleaned(data.mustAlways),
                                mustNever: StructuredEditing.cleaned(data.mustNever),
                                learned: StructuredEditing.cleaned(data.learned))
        let patch = StructuredEditing.patch(original: original, mine: cleaned, parse: RulesDocument.parse, merge: RulesDocument.merge) { raw, data in
            RulesDocument.patch(raw, to: data).mapError { StructuredEditing.ambiguous($0.field.rawValue, $0.reason) }
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
