import SwiftUI

/// agent.yaml as a form (v1 YamlFormEditor): basic info and models are
/// editable; aib_version is read-only (aib sync owns it) and the other
/// top-level blocks are listed as preserved, editable only as raw text.
struct AgentYamlEditorView: View {
    let original: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var config: AgentConfig
    @State private var error: String?
    private let blocked: [String]
    private let otherKeys: [String]

    init(original: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        _config = State(initialValue: AgentYamlDocument.parse(original))
        blocked = AgentYamlDocument.blocked(original).map(\.field.rawValue)
        otherKeys = AgentYamlDocument.otherKeys(original)
    }

    var body: some View {
        StructuredEditorFrame(blocked: blocked, error: error, onCancel: onCancel, onSave: save) {
            Section("기본 정보") {
                TextField("name", text: $config.name)
                TextField("version", text: $config.version).monospaced()
                TextField("description", text: $config.description, axis: .vertical).lineLimit(1...4)
            }
            Section("모델") {
                TextField("primary", text: $config.primaryModel).monospaced()
            }
            BulletListSection(title: "fallback", placeholder: "모델", items: $config.fallbackModels)
            Section {
                LabeledContent("aib_version", value: config.aibVersion.isEmpty ? "—" : config.aibVersion).monospaced()
                if !otherKeys.isEmpty {
                    LabeledContent("그 밖의 키", value: otherKeys.joined(separator: ", "))
                }
            } header: {
                Text("읽기 전용")
            } footer: {
                Text("aib_version은 aib sync가 관리합니다. 그 밖의 키는 저장해도 그대로 보존되며 원문 편집으로만 바꿀 수 있습니다.")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            }
        }
    }

    private func save() {
        let line = { (text: String) in StructuredEditing.singleLine(text).trimmingCharacters(in: .whitespaces) }
        var next = config
        next.name = line(config.name)
        next.version = line(config.version)
        next.description = line(config.description)
        next.primaryModel = line(config.primaryModel)
        next.fallbackModels = StructuredEditing.cleaned(config.fallbackModels).map(line)
        switch AgentYamlDocument.patch(original, to: next) {
        case let .success(raw): onSave(raw)
        case let .failure(failure): error = StructuredEditing.ambiguous(failure.field.rawValue, "\(failure.reason)")
        }
    }
}
