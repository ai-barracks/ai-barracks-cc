import SwiftUI

/// New / edit skill (v1 SkillEditorDialog): a form for the frontmatter the
/// aib protocol defines plus the body, or the whole SKILL.md as text.
struct SkillEditorSheet: View {
    enum Mode {
        case create
        case edit(slug: String, original: String)
    }

    let barrack: URL
    let mode: Mode
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var slug = ""
    @State private var fields = SkillFields()
    @State private var bodyText = ""
    @State private var isRaw = false
    @State private var rawText = ""
    /// The text form edits apply to: the original, or the raw text the user
    /// edited before switching back to the form (r5: raw edits were lost).
    @State private var formBase = ""
    @State private var error: String?
    /// Why the form cannot represent this file (it opens as raw text).
    private let formUnavailable: String?

    init(barrack: URL, mode: Mode, onSaved: @escaping (String) -> Void) {
        self.barrack = barrack
        self.mode = mode
        self.onSaved = onSaved
        guard case let .edit(slug, original) = mode else {
            formUnavailable = nil
            return
        }
        let multiline = SkillDocument.multilineKeys(original).map(\.rawValue)
        formUnavailable = SkillDocument.split(original) == nil ? "frontmatter(---)가 없어 폼으로 열 수 없습니다."
            : multiline.isEmpty ? nil : "\(multiline.joined(separator: ", ")) 값이 여러 줄이라 폼으로 열 수 없습니다."
        _slug = State(initialValue: slug)
        _fields = State(initialValue: SkillDocument.fields(original))
        _bodyText = State(initialValue: SkillDocument.split(original)?.body ?? original)
        _rawText = State(initialValue: original)
        _formBase = State(initialValue: original)
        _isRaw = State(initialValue: formUnavailable != nil)
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isRaw {
                TextEditor(text: $rawText).font(.system(size: 12).monospaced()).padding(Tokens.Spacing.s)
            } else {
                form
            }
            footer
        }
        .frame(width: 720, height: 640)
    }

    private var header: some View {
        HStack {
            Text(isCreate ? "새 Skill" : "Skill 편집 · \(slug)").font(.headline)
            Spacer()
            if !isCreate {
                Picker("", selection: Binding(get: { isRaw }, set: { switchMode($0) })) {
                    Text("폼").tag(false)
                    Text("원문").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .disabled(formUnavailable != nil)
            }
        }
        .padding(Tokens.Spacing.m)
    }

    private var form: some View {
        Form {
            Section("식별") {
                if isCreate {
                    TextField("slug", text: $slug, prompt: Text("kebab-case, 예: open-pr")).monospaced()
                    if let problem = SkillDocument.validate(slug: slug), !slug.isEmpty { hint(problem) }
                } else {
                    LabeledContent("slug", value: slug).monospaced()
                }
                stacked("description") {
                    TextField("description", text: $fields.description, prompt: Text("언제 이 skill을 호출해야 하는지"), axis: .vertical)
                        .lineLimit(2...6)
                }
                if fields.description.count < SkillDocument.minimumDescription {
                    hint("description은 \(SkillDocument.minimumDescription)자 이상(현재 \(fields.description.count)) — 에이전트가 이 문장으로 skill을 찾습니다")
                }
            }
            Section("선택") {
                stacked("argument-hint") { TextField("argument-hint", text: $fields.argumentHint, prompt: Text("[arg1] [arg2]")) }
                stacked("allowed-tools") {
                    TextField("allowed-tools", text: $fields.allowedTools, prompt: Text("Bash(./scripts/foo *), Read")).monospaced()
                }
            }
            Section("본문 (에이전트가 호출할 때 읽는 지시)") {
                TextEditor(text: $bodyText).font(.system(size: 12).monospaced()).frame(minHeight: 220)
                if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hint("본문이 비었습니다 — 언제·어떻게·예시를 적으세요") }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            if let message = formUnavailable ?? error {
                Text(message).font(Tokens.Font.meta).foregroundStyle(error == nil ? Tokens.orange : Tokens.red).lineLimit(3)
            }
            Spacer()
            Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("저장 후 sync", action: save).keyboardShortcut("s", modifiers: .command)
        }
        .padding(Tokens.Spacing.m)
    }

    /// Label above a full-width, leading-aligned field (long values read
    /// badly right-aligned in a grouped form).
    private func stacked(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            field().labelsHidden()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(Tokens.Font.meta).foregroundStyle(Tokens.orange)
    }

    private var cleanedFields: SkillFields {
        let line = { (text: String) in StructuredEditing.singleLine(text).trimmingCharacters(in: .whitespaces) }
        return SkillFields(description: line(fields.description), argumentHint: line(fields.argumentHint), allowedTools: line(fields.allowedTools))
    }

    /// Carries the edits across: form → raw renders them, raw → form re-reads.
    private func switchMode(_ raw: Bool) {
        guard case .edit = mode else { return }
        if raw {
            if case let .success(text) = SkillEditBuffer.toRaw(base: formBase, fields: cleanedFields, body: bodyText) { rawText = text }
        } else {
            guard let loaded = SkillEditBuffer.toForm(raw: rawText) else {
                error = "원문을 폼으로 읽을 수 없습니다(frontmatter 또는 여러 줄 값)."
                return
            }
            (formBase, fields, bodyText) = (rawText, loaded.fields, loaded.body)
        }
        error = nil
        isRaw = raw
    }

    private func save() {
        error = nil
        switch mode {
        case .create: saveNew()
        case let .edit(slug, original): saveEdit(slug, original)
        }
    }

    private func saveNew() {
        if let problem = SkillDocument.validate(slug: slug) { return error = problem }
        let fields = cleanedFields
        guard fields.description.count >= SkillDocument.minimumDescription else {
            return error = "description을 \(SkillDocument.minimumDescription)자 이상 적으세요."
        }
        switch SkillFiles.create(in: barrack, slug: slug, content: SkillDocument.render(slug: slug, fields: fields, body: bodyText)) {
        case .success: finish(slug)
        case let .failure(failure): error = failure.message
        }
    }

    private func saveEdit(_ slug: String, _ original: String) {
        let edited: String
        if isRaw {
            // The aib skills doctor rules, so a raw save cannot break the catalog.
            guard SkillDocument.split(rawText) != nil else { return error = "frontmatter(--- … ---)가 필요합니다." }
            guard SkillDocument.name(rawText) == slug else { return error = "frontmatter의 name이 slug(\(slug))와 같아야 합니다." }
            guard !SkillDocument.fields(rawText).description.isEmpty else { return error = "description이 필요합니다." }
            edited = rawText
        } else {
            guard cleanedFields.description.count >= SkillDocument.minimumDescription else {
                return error = "description을 \(SkillDocument.minimumDescription)자 이상 적으세요."
            }
            switch SkillEditBuffer.toRaw(base: formBase, fields: cleanedFields, body: bodyText) {
            case let .success(text): edited = text
            case let .failure(failure): return error = "폼으로 저장할 수 없습니다(\(failure)). 원문으로 편집하세요."
            }
        }
        switch SkillFiles.update(in: barrack, slug: slug, original: original, edited: edited) {
        case .success: finish(slug)
        case let .failure(failure): error = failure.message
        }
    }

    private func finish(_ slug: String) {
        onSaved(slug)
        dismiss()
    }
}

/// Rename (v1 rename_skill): moves the directory and updates `name:`.
struct SkillRenameSheet: View {
    let barrack: URL
    let slug: String
    let onRenamed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newSlug = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text("Skill 이름 변경 · \(slug)").font(.headline)
            Text("skills/\(slug)/를 새 slug로 옮기고 SKILL.md의 name을 바꿉니다. 이 skill을 이름으로 부르는 문서·다른 skill은 직접 고쳐야 합니다.")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            TextField("새 slug", text: $newSlug).textFieldStyle(.roundedBorder).monospaced()
            if let message = error ?? (newSlug.isEmpty ? nil : SkillDocument.validate(slug: newSlug)) {
                Text(message).font(Tokens.Font.meta).foregroundStyle(Tokens.red)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("이름 변경 후 sync") { rename() }
                    .disabled(newSlug == slug || SkillDocument.validate(slug: newSlug) != nil)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 460)
        .onAppear { newSlug = slug }
    }

    private func rename() {
        switch SkillFiles.rename(in: barrack, from: slug, to: newSlug) {
        case .success:
            onRenamed(newSlug)
            dismiss()
        case let .failure(failure):
            error = failure.message
        }
    }
}

/// Delete with typed-slug confirmation (v1 SkillDeleteDialog); the
/// directory goes to the Trash, so it can be put back.
struct SkillDeleteSheet: View {
    let barrack: URL
    let slug: String
    var remover: SkillFiles.Remover = SkillFiles.moveToTrash
    let onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text("Skill 삭제 · \(slug)").font(.headline)
            Text("skills/\(slug)/ 전체(SKILL.md, scripts/, references/)를 휴지통으로 옮깁니다. 확인하려면 slug를 입력하세요.")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            TextField(slug, text: $typed).textFieldStyle(.roundedBorder).monospaced()
            if let error { Text(error).font(Tokens.Font.meta).foregroundStyle(Tokens.red) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("휴지통으로 옮긴 후 sync", role: .destructive) { delete() }.disabled(typed != slug)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 460)
    }

    private func delete() {
        switch SkillFiles.remove(in: barrack, slug: slug, using: remover) {
        case .success:
            onDeleted()
            dismiss()
        case let .failure(failure):
            error = failure.message
        }
    }
}

/// The editor's form ⇄ raw round trip, kept pure so it can be tested: the
/// form always applies to the text it was last loaded from.
enum SkillEditBuffer {
    static func toRaw(base: String, fields: SkillFields, body: String) -> Result<String, SkillDocument.Failure> {
        SkillDocument.patch(base, fields: fields, body: body)
    }

    static func toForm(raw: String) -> (fields: SkillFields, body: String)? {
        guard let parts = SkillDocument.split(raw), SkillDocument.multilineKeys(raw).isEmpty else { return nil }
        return (SkillDocument.fields(raw), parts.body)
    }
}
