import SwiftUI

/// v1 System's batch sync (Codex parity audit P05): every barrack with its
/// aib version, any subset picked by hand or "업데이트 필요만", a dry run or
/// the real sync, and a result per barrack. The selection is fixed when a
/// run starts; one barrack failing does not stop the others.
@MainActor
@Observable
final class BarrackSyncModel {
    typealias Runner = @Sendable (_ path: String, _ dryRun: Bool) async -> Result

    struct Row: Identifiable, Equatable {
        let barrack: Barrack
        /// agent.yaml's aib_version ("" when absent).
        let version: String
        var id: Barrack.ID { barrack.id }
    }

    struct Result: Equatable, Sendable {
        let success: Bool
        let output: String
    }

    let rows: [Row]
    let cliVersion: String
    var selected: Set<Barrack.ID> = []
    var dryRun = true
    private(set) var results: [Barrack.ID: Result] = [:]
    private(set) var running = false
    /// Whether the last run was a dry run (what the results mean).
    private(set) var lastRunWasDry = true
    @ObservationIgnored private let runner: Runner

    init(barracks: [Barrack], cliVersion: String, runner: @escaping Runner = BarrackSyncModel.aibSync) {
        rows = barracks.map { Row(barrack: $0, version: Self.version(of: $0)) }
        self.cliVersion = cliVersion
        self.runner = runner
    }

    func isOutdated(_ row: Row) -> Bool {
        !cliVersion.isEmpty && !row.version.isEmpty && row.version != cliVersion
    }

    func selectAll() { selected = Set(rows.map(\.id)) }
    func selectNone() { selected = [] }
    func selectOutdated() { selected = Set(rows.filter(isOutdated).map(\.id)) }

    /// One barrack at a time (a real sync re-registers it), in list order.
    func run() async {
        guard !running else { return }
        let targets = rows.filter { selected.contains($0.id) }
        let dry = dryRun
        guard !targets.isEmpty else { return }
        running = true
        lastRunWasDry = dry
        results = [:]
        for row in targets {
            results[row.id] = await runner(row.barrack.path, dry)
        }
        running = false
    }

    nonisolated static func version(of barrack: Barrack) -> String {
        guard let yaml = try? String(contentsOfFile: barrack.path + "/agent.yaml", encoding: .utf8),
              let line = yaml.split(separator: "\n").first(where: { $0.hasPrefix("aib_version:") }) else { return "" }
        return line.dropFirst("aib_version:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    /// `aib sync [--dry-run] .` in the barrack; real syncs go through the
    /// write queue shared with every other aib write.
    static let aibSync: Runner = { path, dryRun in
        let command = "aib sync \(dryRun ? "--dry-run " : "")."
        let run = { @Sendable in
            await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/bin/zsh"), ["-lc", command], in: path)
        }
        let result = dryRun ? await run() : await AibWriteQueue.run(run)
        return Result(success: result.status == 0, output: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct BarrackSyncSheet: View {
    let workspace: WorkspaceModel
    @State var model: BarrackSyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Barrack.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack {
                Text("배럭 Sync").font(Tokens.Font.title)
                Spacer()
                Text(model.cliVersion.isEmpty ? "aib CLI 버전 확인 중" : "aib CLI v\(model.cliVersion)")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            }
            HStack {
                Button("전체") { model.selectAll() }
                Button("없음") { model.selectNone() }
                Button("업데이트 필요만") { model.selectOutdated() }
                Spacer()
                Toggle("미리보기(dry-run)", isOn: $model.dryRun).toggleStyle(.checkbox)
            }
            .controlSize(.small)
            .disabled(model.running)
            List(model.rows) { row in rowView(row) }
                .frame(minHeight: 220)
            HStack {
                if model.running { ProgressView().controlSize(.small) }
                Text(summary).font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.running)
                Button(model.dryRun ? "미리보기 \(model.selected.count)" : "Sync \(model.selected.count)") {
                    Task {
                        await model.run()
                        if !model.lastRunWasDry { workspace.refreshBarracks() }
                    }
                }
                .disabled(model.selected.isEmpty || model.running)
            }
        }
        .padding(Tokens.Spacing.l * 1.5)
        .frame(width: 620, height: 520)
    }

    private func rowView(_ row: BarrackSyncModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { model.selected.contains(row.id) },
                                     set: { model.selected = $0 ? model.selected.union([row.id]) : model.selected.subtracting([row.id]) })) {
                    Text(row.barrack.name).font(Tokens.Font.body)
                }
                .toggleStyle(.checkbox)
                .disabled(model.running)
                Spacer()
                Text(row.version.isEmpty ? "버전 없음" : "v\(row.version)").font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
                Text(model.isOutdated(row) ? "업데이트 필요" : "최신")
                    .font(Tokens.Font.meta).foregroundStyle(model.isOutdated(row) ? Tokens.orange : Tokens.green)
                if let result = model.results[row.id] {
                    Button {
                        expanded = expanded == row.id ? nil : row.id
                    } label: {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.success ? Tokens.green : Tokens.red)
                    }
                    .buttonStyle(.borderless)
                    .help(result.success ? "성공 — 눌러서 출력 보기" : "실패 — 눌러서 출력 보기")
                }
            }
            if expanded == row.id, let result = model.results[row.id] {
                ScrollView {
                    Text(result.output.isEmpty ? "(출력 없음)" : result.output)
                        .font(.system(size: 11).monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private var summary: String {
        guard !model.results.isEmpty else { return "\(model.selected.count)개 선택" }
        let failed = model.results.values.filter { !$0.success }.count
        let kind = model.lastRunWasDry ? "미리보기" : "Sync"
        return "\(kind): 성공 \(model.results.count - failed) · 실패 \(failed)"
    }
}
