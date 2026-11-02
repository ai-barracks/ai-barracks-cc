import SwiftUI

/// In-app notices (v1 NotificationToast): top-right, newest last, each with
/// its action and a close button; they leave on their own after a while.
struct ToastStack: View {
    let workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .trailing, spacing: Tokens.Spacing.s) {
            ForEach(workspace.notices.notices) { notice in
                HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                    Image(systemName: symbol(notice.kind)).foregroundStyle(tint(notice.kind))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.title).font(Tokens.Font.bodyMedium)
                        Text(notice.body).font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary).lineLimit(2)
                        if let label = notice.actionLabel {
                            Button(label) { workspace.perform(notice) }.controlSize(.small).padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { workspace.notices.dismiss(notice.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(Tokens.Spacing.m)
                .frame(width: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .shadow(radius: 8, y: 2)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(Tokens.Spacing.l)
        .animation(Tokens.Motion.transition, value: workspace.notices.notices.map(\.id))
    }

    private func symbol(_ kind: AppNotice.Kind) -> String {
        switch kind {
        case .stale: "hourglass"
        case .sync: "arrow.triangle.2.circlepath"
        case .attention: "exclamationmark.circle.fill"
        case .export: "square.and.arrow.up"
        }
    }

    private func tint(_ kind: AppNotice.Kind) -> Color {
        kind == .attention ? Tokens.orange : Tokens.teal
    }
}
