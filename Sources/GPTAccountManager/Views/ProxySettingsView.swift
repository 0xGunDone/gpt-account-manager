import SwiftUI

struct ProxySettingsView: View {
    let store: ProxyStore
    let canEdit: Bool
    let onClose: () -> Void

    @State private var proxyText = ""
    @State private var proxyLabel = ""
    @State private var editingProxyID: UUID?
    @State private var editingProxyEnabled = true
    @State private var sourceURL = ""
    @State private var editingSourceID: UUID?
    @State private var error: String?
    @State private var taskRunning = false

    private var busy: Bool { taskRunning || store.isChecking || store.isRefreshing }
    private var editsDisabled: Bool { !canEdit || busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Прокси").font(.title2.bold())
                Spacer()
                Toggle("Использовать прокси", isOn: Binding(
                    get: { store.isEnabled },
                    set: { enabled in perform { try store.setEnabled(enabled) } }))
                    .toggleStyle(.switch)
                    .disabled(editsDisabled)
                Button("Закрыть", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text("Для новой регистрации выбирается случайный доступный прокси. Выбранный адрес закрепляется за аккаунтом.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Переключатель действует при следующем открытии сессии. Открытые сессии продолжают работать как раньше. При выключении новые сессии подключаются напрямую.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Публичный прокси видит адреса подключений; пароли передаются внутри HTTPS.")
                .font(.caption).foregroundStyle(.secondary)

            TabView {
                proxyList.tabItem { Text("Адреса · \(store.proxies.count)") }
                sourceList.tabItem { Text("Источники · \(store.sources.count)") }
            }

            if !canEdit {
                Text("Настройки можно менять после завершения текущей операции.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let status = store.status {
                Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(minWidth: 820, idealWidth: 960, minHeight: 650, idealHeight: 820)
    }

    private var proxyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Включено в выбор: \(store.proxies.filter(\.isEnabled).count)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if store.isChecking { ProgressView().controlSize(.small) }
                Button("Проверить все") {
                    performAsync { await store.checkAll() }
                }
                .disabled(editsDisabled || store.proxies.isEmpty)
            }
            List {
                ForEach(store.proxies) { entry in
                    proxyRow(entry)
                }
            }
            .overlay {
                if store.proxies.isEmpty {
                    ContentUnavailableView("Нет прокси", systemImage: "network",
                        description: Text("Вставьте адреса ниже или загрузите список во вкладке «Источники»."))
                }
            }
            .frame(minHeight: 180)

            VStack(alignment: .leading, spacing: 8) {
                Text(editingProxyID == nil ? "Добавить адреса" : "Изменить прокси").font(.headline)
                Text(editingProxyID == nil
                     ? "Один адрес на строку: host:port или host:port:login:password. Также поддерживаются http://, https:// и socks5://."
                     : "Укажите адрес с портом. Для авторизации: host:port:login:password или protocol://login:password@host:port.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $proxyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: editingProxyID == nil ? 76 : 42)
                    .border(.separator)
                    .accessibilityLabel(editingProxyID == nil ? "Новые прокси, по одному на строку" : "Адрес прокси")
                HStack {
                    TextField("Название или страна (необязательно)", text: $proxyLabel)
                        .textFieldStyle(.roundedBorder)
                    if editingProxyID != nil {
                        Toggle("Включён", isOn: $editingProxyEnabled).toggleStyle(.checkbox)
                        Button("Отмена", action: resetProxyEditor)
                    }
                    Button(editingProxyID == nil ? "Добавить" : "Сохранить") { saveProxy() }
                        .buttonStyle(.borderedProminent)
                        .disabled(proxyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(editsDisabled)
        }
        .padding(14)
    }

    private func proxyRow(_ entry: ProxyEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Использовать \(entry.proxy.displayName)", isOn: Binding(
                get: { entry.isEnabled },
                set: { enabled in
                    perform {
                        try store.update(id: entry.id, text: entry.proxy.editableString,
                                         label: entry.label, isEnabled: enabled)
                    }
                }))
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(editsDisabled)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.proxy.displayName)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    if !entry.label.isEmpty {
                        Text(entry.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    if store.checkingIDs.contains(entry.id) {
                        ProgressView().controlSize(.mini)
                        Text("Проверка…").foregroundStyle(.secondary)
                    } else if let check = entry.check {
                        Label(check.status == .available ? "Доступен" : "Недоступен",
                              systemImage: check.status == .available ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(check.status == .available ? Color.green : Color.red)
                            .help(check.message)
                        if let latency = check.latencyMilliseconds { Text("\(latency) мс") }
                        if let ip = check.exitIP { Text("Внешний IP: \(ip)").textSelection(.enabled) }
                        Text(check.checkedAt, format: .dateTime.day().month().hour().minute())
                            .help("Последняя проверка")
                    } else {
                        Text("Не проверен")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Проверить") { performAsync { await store.check(id: entry.id) } }
                Button("Изменить") {
                    editingProxyID = entry.id
                    proxyText = entry.proxy.editableString
                    proxyLabel = entry.label
                    editingProxyEnabled = entry.isEnabled
                    error = nil
                }
                Button("Удалить") {
                    perform {
                        try store.remove(id: entry.id)
                        if editingProxyID == entry.id { resetProxyEditor() }
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(editsDisabled)
        }
        .padding(.vertical, 5)
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Списки загружаются по указанным ссылкам. Повторные адреса пропускаются.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button("Загрузить списки") {
                    performAsync { _ = try await store.refreshSources() }
                }
                .disabled(editsDisabled || store.sources.isEmpty)
            }
            List {
                ForEach(store.sources) { source in
                    HStack {
                        Text(source.url).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("Изменить") {
                            editingSourceID = source.id
                            sourceURL = source.url
                            error = nil
                        }
                        Button("Удалить") {
                            perform {
                                try store.removeSource(id: source.id)
                                if editingSourceID == source.id { resetSourceEditor() }
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(editsDisabled)
                    .padding(.vertical, 5)
                }
            }
            .overlay {
                if store.sources.isEmpty {
                    ContentUnavailableView("Нет источников", systemImage: "link",
                        description: Text("Добавьте ссылку на текстовый список прокси."))
                }
            }
            .frame(minHeight: 180)
            HStack {
                TextField("Ссылка на список прокси", text: $sourceURL)
                    .textFieldStyle(.roundedBorder)
                if editingSourceID != nil { Button("Отмена", action: resetSourceEditor) }
                Button(editingSourceID == nil ? "Добавить источник" : "Сохранить") {
                    perform {
                        if let id = editingSourceID {
                            try store.updateSource(id: id, url: sourceURL)
                        } else {
                            try store.addSource(url: sourceURL)
                        }
                        resetSourceEditor()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(editsDisabled)
        }
        .padding(14)
    }

    private func saveProxy() {
        perform {
            if let id = editingProxyID {
                try store.update(id: id, text: proxyText, label: proxyLabel, isEnabled: editingProxyEnabled)
            } else {
                _ = try store.add(text: proxyText, label: proxyLabel)
            }
            resetProxyEditor()
        }
    }

    private func resetProxyEditor() {
        editingProxyID = nil
        proxyText = ""
        proxyLabel = ""
        editingProxyEnabled = true
    }

    private func resetSourceEditor() {
        editingSourceID = nil
        sourceURL = ""
    }

    private func perform(_ operation: () throws -> Void) {
        guard !editsDisabled else { return }
        error = nil
        do { try operation() }
        catch { self.error = error.localizedDescription }
    }

    private func performAsync(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !editsDisabled else { return }
        error = nil
        taskRunning = true
        Task { @MainActor in
            defer { taskRunning = false }
            do { try await operation() }
            catch { self.error = error.localizedDescription }
        }
    }
}
