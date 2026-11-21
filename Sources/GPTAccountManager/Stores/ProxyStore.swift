import Foundation
import Observation

@MainActor
@Observable
final class ProxyStore {
    typealias Checker = @Sendable (AccountProxy) async -> ProxyCheckResult
    typealias SourceLoader = @Sendable (URL) async throws -> String

    private(set) var proxies: [ProxyEntry] = []
    private(set) var sources: [ProxySource] = []
    private(set) var isLoaded = false
    private(set) var isEnabled = false
    private(set) var isRefreshing = false
    private(set) var checkingIDs: Set<UUID> = []
    private(set) var status: String?
    var isChecking: Bool { !checkingIDs.isEmpty }
    let fileURL: URL
    @ObservationIgnored private let checker: Checker
    @ObservationIgnored private let sourceLoader: SourceLoader
    @ObservationIgnored private let shuffled: ([ProxyEntry]) -> [ProxyEntry]
    @ObservationIgnored private var checkCounts: [UUID: Int] = [:]

    init(
        fileURL: URL = ProxyStore.defaultFileURL(),
        checker: @escaping Checker = ProxyChecker.check,
        sourceLoader: @escaping SourceLoader = ProxyChecker.fetchSource,
        shuffled: @escaping ([ProxyEntry]) -> [ProxyEntry] = { $0.shuffled() }
    ) {
        self.fileURL = fileURL
        self.checker = checker
        self.sourceLoader = sourceLoader
        self.shuffled = shuffled
    }

    static func defaultFileURL() -> URL {
        AccountStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("proxies.json")
    }

    func load(initiallyEnabled: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try commit(enabled: initiallyEnabled, proxies: [], sources: [])
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try verifyPermissions(fileURL, expected: 0o600)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(PersistedProxies.self, from: Data(contentsOf: fileURL))
        guard value.version == 1 else { throw ProxyStoreError.unsupportedVersion }
        guard Set(value.proxies.map(\.id)).count == value.proxies.count,
              Set(value.proxies.map(\.proxy)).count == value.proxies.count,
              Set(value.sources.map(\.id)).count == value.sources.count else { throw ProxyStoreError.invalidProxy }
        for source in value.sources { _ = try sourceURL(source.url) }
        isEnabled = value.isEnabled
        proxies = value.proxies
        sources = value.sources
        isLoaded = true
    }

    func setEnabled(_ enabled: Bool) throws {
        try commit(enabled: enabled, proxies: proxies, sources: sources)
    }

    @discardableResult
    func add(text: String, label: String = "") throws -> Int {
        let parsed = Self.parseList(text)
        guard !parsed.proxies.isEmpty else { throw ProxyStoreError.noValidProxies }
        let added = try merge(parsed.proxies, label: label)
        status = "Добавлено: \(added). Уже в списке: \(parsed.proxies.count - added). Пропущено строк: \(parsed.skipped) (неверный формат или неподдерживаемый протокол)."
        return added
    }

    func update(id: UUID, text: String, label: String, isEnabled: Bool) throws {
        let proxy = try AccountProxy.parse(text)
        guard let index = proxies.firstIndex(where: { $0.id == id }) else { throw ProxyStoreError.missingProxy }
        guard !proxies.contains(where: { $0.id != id && $0.proxy == proxy }) else { throw ProxyStoreError.duplicateProxy }
        var candidate = proxies
        if candidate[index].proxy != proxy { candidate[index].check = nil }
        candidate[index].proxy = proxy
        candidate[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate[index].isEnabled = isEnabled
        try commit(enabled: self.isEnabled, proxies: candidate, sources: sources)
    }

    func remove(id: UUID) throws {
        try commit(enabled: isEnabled, proxies: proxies.filter { $0.id != id }, sources: sources)
    }

    func addSource(url: String) throws {
        let url = try sourceURL(url).absoluteString
        guard !sources.contains(where: { $0.url == url }) else { throw ProxyStoreError.duplicateSource }
        try commit(enabled: isEnabled, proxies: proxies, sources: sources + [.init(url: url)])
    }

    func updateSource(id: UUID, url: String) throws {
        let url = try sourceURL(url).absoluteString
        guard !sources.contains(where: { $0.id != id && $0.url == url }) else { throw ProxyStoreError.duplicateSource }
        guard let index = sources.firstIndex(where: { $0.id == id }) else { throw ProxyStoreError.invalidSource }
        var candidate = sources
        candidate[index].url = url
        try commit(enabled: isEnabled, proxies: proxies, sources: candidate)
    }

    func removeSource(id: UUID) throws {
        try commit(enabled: isEnabled, proxies: proxies, sources: sources.filter { $0.id != id })
    }

    @discardableResult
    func refreshSources() async throws -> Int {
        guard !isRefreshing else { return 0 }
        guard !sources.isEmpty else { throw ProxyStoreError.noSources }
        isRefreshing = true
        defer { isRefreshing = false }
        var incoming: [AccountProxy] = []
        var failures: [String] = []
        var skipped = 0
        for source in sources {
            try Task.checkCancellation()
            do {
                let text = try await sourceLoader(sourceURL(source.url))
                guard text.utf8.count <= 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
                let parsed = Self.parseList(text)
                guard !parsed.proxies.isEmpty else { throw ProxyStoreError.noValidProxies }
                guard sources.contains(source) else { continue }
                incoming += parsed.proxies
                skipped += parsed.skipped
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        guard !incoming.isEmpty else { throw ProxyStoreError.sourceDownload(failures.joined(separator: " ")) }
        let added = try merge(incoming, label: "")
        status = "Добавлено из источников: \(added). Пропущено строк: \(skipped) (включая SOCKS4). Ошибок источников: \(failures.count)."
        return added
    }

    func check(id: UUID) async {
        guard !checkingIDs.contains(id), let entry = proxies.first(where: { $0.id == id }) else { return }
        do {
            _ = try await performCheck(entry)
        } catch {
            status = error.localizedDescription
        }
    }

    func checkAll() async {
        guard !isChecking else { return }
        let ids = proxies.map(\.id)
        guard !ids.isEmpty else { status = "Нет прокси для проверки."; return }
        status = "Проверка \(ids.count) прокси…"
        // ponytail: four probes at once; avoids flooding large public lists.
        await withTaskGroup(of: Void.self) { group in
            var remaining = ids.makeIterator()
            for _ in 0..<4 {
                if let id = remaining.next() { group.addTask { await self.check(id: id) } }
            }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if let id = remaining.next() { group.addTask { await self.check(id: id) } }
            }
        }
        let available = proxies.filter { ids.contains($0.id) && $0.check?.status == .available }.count
        status = Task.isCancelled ? "Проверка отменена." : "Проверено: \(ids.count). Доступно: \(available)."
    }

    func checkedProxy(replacing current: AccountProxy) async throws -> AccountProxy? {
        try Task.checkCancellation()
        guard isEnabled else { return nil }
        // Assignments survive edits/removal from the pool until their own probe fails.
        let entry = proxies.first(where: { $0.proxy == current }) ?? ProxyEntry(proxy: current)
        let result = try await performCheck(entry)
        try Task.checkCancellation()
        guard isEnabled else { return nil }
        if result.status == .available { return current }
        return try await chooseProxy(excluding: [current], maximumAttempts: 11)
    }

    func chooseForNewAccount(excluding excluded: Set<AccountProxy> = []) async throws -> AccountProxy? {
        try await chooseProxy(excluding: excluded, maximumAttempts: 12)
    }

    private func chooseProxy(excluding excluded: Set<AccountProxy>, maximumAttempts: Int) async throws -> AccountProxy? {
        try Task.checkCancellation()
        guard isEnabled else { return nil }
        let enabled = proxies.filter { $0.isEnabled && !excluded.contains($0.proxy) }
        let now = Date()
        let healthy = enabled.filter {
            guard let check = $0.check else { return false }
            return check.status == .available && (0...1800).contains(now.timeIntervalSince(check.checkedAt))
        }
        let healthyIDs = Set(healthy.map(\.id))
        let candidates = shuffled(healthy) + shuffled(enabled.filter { !healthyIDs.contains($0.id) })
        status = "Выбор рабочего прокси…"
        // Recheck even a fresh cached success. Proxy mode never falls back to direct traffic.
        for entry in candidates.prefix(maximumAttempts) {
            try Task.checkCancellation()
            let result = try await performCheck(entry)
            try Task.checkCancellation()
            guard isEnabled else { return nil }
            if result.status == .available,
               proxies.contains(where: { $0.id == entry.id && $0.proxy == entry.proxy && $0.isEnabled }) {
                status = "Выбран прокси: \(entry.proxy.displayName)"
                return entry.proxy
            }
        }
        throw ProxyStoreError.noAvailableProxy
    }

    private func performCheck(_ entry: ProxyEntry) async throws -> ProxyCheckResult {
        checkCounts[entry.id, default: 0] += 1
        checkingIDs.insert(entry.id)
        defer {
            checkCounts[entry.id, default: 0] -= 1
            if checkCounts[entry.id] == 0 {
                checkCounts.removeValue(forKey: entry.id)
                checkingIDs.remove(entry.id)
            }
        }
        let result = await checker(entry.proxy)
        try Task.checkCancellation()
        if let index = proxies.firstIndex(where: { $0.id == entry.id && $0.proxy == entry.proxy }) {
            var candidate = proxies
            candidate[index].check = result
            try commit(enabled: isEnabled, proxies: candidate, sources: sources)
        }
        return result
    }

    private func merge(_ incoming: [AccountProxy], label: String) throws -> Int {
        var known = Set(proxies.map(\.proxy))
        let additions = incoming.filter { known.insert($0).inserted }.map {
            ProxyEntry(proxy: $0, label: label.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try commit(enabled: isEnabled, proxies: proxies + additions, sources: sources)
        return additions.count
    }

    private static func parseList(_ text: String) -> (proxies: [AccountProxy], skipped: Int) {
        var proxies: [AccountProxy] = []
        var skipped = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let proxy = try? AccountProxy.parse(line) { proxies.append(proxy) } else { skipped += 1 }
        }
        return (proxies, skipped)
    }

    private func sourceURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ProxyChecker.validSourceURL(url) else { throw ProxyStoreError.invalidSource }
        return url
    }

    private func commit(enabled: Bool, proxies: [ProxyEntry], sources: [ProxySource]) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try verifyPermissions(directory, expected: 0o700)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PersistedProxies(isEnabled: enabled, proxies: proxies, sources: sources))
        let temporary = directory.appendingPathComponent(".proxies-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw ProxyStoreError.insecurePermissions }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try verifyPermissions(temporary, expected: 0o600)
        if manager.fileExists(atPath: fileURL.path) {
            _ = try manager.replaceItemAt(fileURL, withItemAt: temporary, options: [.usingNewMetadataOnly])
        } else {
            try manager.moveItem(at: temporary, to: fileURL)
        }
        try verifyPermissions(fileURL, expected: 0o600)
        self.isEnabled = enabled
        self.proxies = proxies
        self.sources = sources
        self.isLoaded = true
    }

    private func verifyPermissions(_ url: URL, expected: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == expected else { throw ProxyStoreError.insecurePermissions }
    }

    private struct PersistedProxies: Codable {
        var version = 1
        var isEnabled: Bool
        var proxies: [ProxyEntry]
        var sources: [ProxySource]
    }
}
