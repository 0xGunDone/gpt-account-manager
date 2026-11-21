import SwiftUI

struct BrowserRecoveryControlsView: View {
    let availability: BrowserRecoveryAvailability
    let onReload: () -> Void
    let onReopen: () -> Void
    let onFreshLogin: () -> Void
    let onReturnToOriginal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Восстановление браузера")
                .font(.headline)
            Text(availability.warning)
                .font(.callout)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Обновить страницу", action: onReload)
            .disabled(!availability.canReload)
        if availability.reopenDestination != nil {
            Button("Открыть раздел заново", action: onReopen)
        }
        Button("Новый вход", action: onFreshLogin)
        if availability.canReturnToOriginalSession {
            Button("Вернуться в исходную сессию", action: onReturnToOriginal)
        }
    }
}
