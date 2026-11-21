import SwiftUI

struct AccessChangeSheet: View {
    let title: String
    let accountCount: Int
    let passwordSetupRequired: Bool
    let onCancel: () -> Void
    let onStart: (AccessChangeMode) -> Void
    @State private var mode: AccessChangeMode = .twoFA

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Сменить доступы").font(.title2.weight(.semibold))
            Text(title).foregroundStyle(.secondary)
            Picker("Что изменить", selection: $mode) {
                ForEach(AccessChangeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            if mode.changesPassword {
                Text(passwordSetupRequired
                     ? NewPasswordConfiguration.unavailableMessage
                     : "Код подтверждения программа получит из подключённого Mail.ru. Используйте только аккаунты, письма которых приходят в этот ящик. Пароль сохранится после проверочного входа.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if mode.changesTwoFA {
                Text(mode.changesPassword
                     ? "Сначала меняется пароль, затем запускается обычная смена 2FA. Старый ключ остаётся основным до проверенного входа с новым ключом."
                     : "Старый ключ остаётся основным до проверочного входа с новым ключом. Подтверждённая сессия сохранится для следующих действий.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if accountCount > 1 {
                Text("Аккаунтов: \(accountCount). Обработка строго по одному. При ошибке или ручном шаге очередь ждёт завершения текущего аккаунта.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Начать") { onStart(mode) }.keyboardShortcut(.defaultAction)
                    .disabled(mode.changesPassword && passwordSetupRequired)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
