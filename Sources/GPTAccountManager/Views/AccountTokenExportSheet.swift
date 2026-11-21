import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AccountTokenExportSheet: View {
    let accounts: [AccountRecord]
    let currentAccounts: () -> [AccountRecord]
    let forbiddenDirectory: URL
    let onClose: () -> Void
    @State private var format: AccountTokenExportFormat = .text
    @State private var message: String?

    private var result: AccountTokenExportResult? {
        try? AccountTokenExport.make(accounts: currentAccounts(), format: format)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Экспорт токенов").font(.title2.bold())
            Picker("Формат", selection: $format) {
                ForEach(AccountTokenExportFormat.allCases) { value in Text(value.title).tag(value) }
            }
            .pickerStyle(.segmented)
            if let result {
                Text("Выбрано: \(accounts.count). Готово к экспорту: \(result.exportedCount). Пропущено: \(accounts.count - result.exportedCount).")
                if result.expiredCount > 0 { Text("Истёкших токенов: \(result.expiredCount)").foregroundStyle(.orange) }
                if let warning = result.warning { Text(warning).foregroundStyle(.secondary) }
                if format == .cpa && result.exportedCount > 1 {
                    Text("CPA: отдельный JSON на каждый аккаунт. Сохранение создаст новую папку; загрузите её файлы в CPA.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Не удалось подготовить экспорт.").foregroundStyle(.red)
            }
            Text("Экспорт содержит токены доступа. Пароли, ключи 2FA и cookies не включаются. JWT-метаданные не подтверждают подпись; совместимость проверяется целевым приложением.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Закрыть", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Копировать") { copy() }.disabled((result?.exportedCount ?? 0) == 0 || (format == .cpa && (result?.exportedCount ?? 0) > 1))
                Button(format == .cpa && (result?.exportedCount ?? 0) > 1 ? "Сохранить JSON-файлы…" : "Сохранить файл…") { save() }
                    .disabled((result?.exportedCount ?? 0) == 0)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 620)
        .onChange(of: format) { _, _ in message = nil }
    }

    private func copy() {
        guard let result, result.exportedCount > 0, !(format == .cpa && result.exportedCount > 1),
              let text = String(data: result.data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        message = NSPasteboard.general.setString(text, forType: .string)
            ? "Скопировано аккаунтов: \(result.exportedCount)." : "Не удалось скопировать экспорт."
    }

    private func save() {
        if format == .cpa && (result?.exportedCount ?? 0) > 1 {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.prompt = "Сохранить JSON-файлы"
            guard panel.runModal() == .OK, let folder = panel.url,
                  let result, result.exportedCount > 0 else { return }
            do {
                _ = try AtomicSecretExport.writeDirectory(documents: result.documents, in: folder, excluding: forbiddenDirectory)
                message = "Сохранено JSON-файлов: \(result.exportedCount)."
            } catch { message = "Не удалось сохранить файлы. Выберите папку вне данных приложения." }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .text ? .plainText : .json]
        panel.nameFieldStringValue = "chatgpt-\(format.rawValue).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Regenerate after the panel closes: deletion or credential edits can invalidate the snapshot.
        guard let result, result.exportedCount > 0 else { message = "Подходящих аккаунтов больше нет."; return }
        guard !(format == .cpa && result.exportedCount > 1) else {
            message = "Состав экспорта изменился. Нажмите «Сохранить JSON-файлы…», чтобы выбрать папку."
            return
        }
        do {
            try AtomicSecretExport.write(result.data, to: url, excluding: forbiddenDirectory)
            message = "Сохранено аккаунтов: \(result.exportedCount)."
        } catch { message = "Не удалось сохранить экспорт. Выберите обычный файл вне папки данных приложения." }
    }
}
