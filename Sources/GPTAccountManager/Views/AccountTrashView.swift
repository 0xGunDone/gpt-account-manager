import SwiftUI

struct AccountTrashView: View {
    let store: AccountStore
    let protectedIDs: Set<UUID>
    let actionsDisabled: Bool
    let onClose: () -> Void
    @State private var pendingPurge: UUID?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Корзина аккаунтов").font(.title2.bold())
                Spacer()
                Button("Закрыть", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text("Удалённые записи хранятся локально до окончательного удаления. Восстановление сохраняет доступы и профиль браузера; алиасы не освобождаются.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if store.deletedAccounts.isEmpty {
                ContentUnavailableView("Корзина пуста", systemImage: "trash")
            } else {
                List(store.deletedAccounts.sorted { $0.deletedAt > $1.deletedAt }) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.account.email).font(.headline)
                            Text(item.group?.name ?? "Без группы").foregroundStyle(.secondary)
                            Text(item.deletedAt, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Восстановить") { restore(item.id) }
                            .disabled(actionsDisabled || protectedIDs.contains(item.account.id))
                        Button("Удалить навсегда", role: .destructive) { pendingPurge = item.id }
                            .disabled(actionsDisabled)
                    }.padding(.vertical, 4)
                }
            }
        }
        .padding(24).frame(minWidth: 760, minHeight: 460)
        .confirmationDialog("Удалить запись из корзины навсегда?", isPresented: Binding(
            get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }), titleVisibility: .visible) {
                Button("Удалить навсегда", role: .destructive) { purge() }
                Button("Отмена", role: .cancel) { pendingPurge = nil }
            } message: { Text("Локальные доступы из этой записи будут удалены без возможности восстановления через приложение.") }
    }

    private func restore(_ id: UUID) {
        guard !actionsDisabled else { return }
        do {
            try store.restoreDeletedAccount(id: id, protectedIDs: protectedIDs)
            message = "Аккаунт восстановлен."
            do { _ = try store.writeRegistrationAccessTokenExport() }
            catch { message = "Аккаунт восстановлен, но файл экспорта ещё не обновлён." }
        } catch AccountStoreError.duplicateAccountEmail {
            message = "Такой аккаунт уже есть. Запись оставлена в корзине."
        } catch { message = "Не удалось восстановить запись: возможен конфликт аккаунта, группы или занятого алиаса." }
    }

    private func purge() {
        guard !actionsDisabled, let id = pendingPurge else { return }
        pendingPurge = nil
        do { try store.removeDeletedAccountPermanently(id: id); message = "Запись удалена из корзины." }
        catch { message = "Не удалось удалить запись. Она осталась в корзине." }
    }
}
