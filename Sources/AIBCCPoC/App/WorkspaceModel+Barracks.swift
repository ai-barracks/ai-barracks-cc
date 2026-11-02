import Foundation

/// Barrack registry changes from the GUI (v1 System view).
extension WorkspaceModel {
    /// Reloads the registry now (the watcher may lag) and selects `path`.
    func registryChanged(select path: String? = nil) {
        reloadRegistry()
        guard let path else { return }
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        if let barrack = barracks.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == wanted }) {
            selectedBarrackID = barrack.id
        }
    }

    /// `aib barracks remove` for a confirmed barrack; files stay on disk.
    func removeConfirmedBarrack() {
        guard let barrack = barrackToRemove else { return }
        barrackToRemove = nil
        Task {
            let outcome = await BarrackAdmin.remove(barrack.path)
            registryChanged()
            notices.post(AppNotice(kind: .registry, title: outcome.ok ? "목록에서 제거: \(barrack.name)" : "제거 실패: \(barrack.name)",
                                   body: outcome.ok ? "파일은 그대로입니다 · \(barrack.path)" : outcome.output,
                                   actionLabel: nil, barrackID: nil, sessionID: nil))
        }
    }

    /// `aib barracks refresh`: metadata re-read, missing directories dropped.
    func refreshBarracks() {
        Task {
            let outcome = await BarrackAdmin.refresh()
            registryChanged()
            notices.post(AppNotice(kind: .registry, title: outcome.ok ? "배럭 목록 새로 고침" : "새로 고침 실패",
                                   body: outcome.output.split(separator: "\n").last.map(String.init) ?? "",
                                   actionLabel: nil, barrackID: nil, sessionID: nil))
        }
    }
}
