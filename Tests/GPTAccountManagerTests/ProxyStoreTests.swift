import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct ProxyStoreTests {
    private func fileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("proxies.json")
    }

    @Test func parserAcceptsSupportedSchemesAndRejectsUnsafeOrUnsupportedInput() throws {
        #expect(try AccountProxy.parse("  EXAMPLE.com:3128 ").urlString == "http://example.com:3128")
        #expect(try AccountProxy.parse("socks5://[2001:db8::1]:1080").host == "2001:db8::1")
        #expect(try AccountProxy.parse("https://127.0.0.1:443").scheme == .https)
        for value in ["socks4://127.0.0.1:1080", "127.0.0.1:0", "127.0.0.1:65536", "http://999.1.2.3:80", "http://-host:80", "http://host:80/path", "http://host:80?q=1", "http://host:80#fragment", "http://host:80/", "http://host name:80"] {
            #expect(throws: (any Error).self) { try AccountProxy.parse(value) }
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AccountProxy.self, from: Data(#"{"scheme":"http","host":"host","port":-1}"#.utf8))
        }
    }

    @Test func authenticatedProxyFormatsRoundTripWithoutExposingCredentials() throws {
        for input in [
            "host:8080:fixture-user:fixture-pass",
            "https://host:8443:fixture-user:fixture-pass",
            "socks5://[2001:db8::1]:1080:fixture-user:fixture:pass",
            "http://fixture-user:fixture-pass@host:8080",
            "http://fixture-user:123:fixture-pass@host:8080",
            "http://123:abc:def@host:8080",
            "socks5://fixture-user:fixture-pass@[2001:db8::1]:1080",
            "host:8080:fixture@user:fixture:pass/?#%",
            "host:8080:fixture-user:fixture://pass",
            "https://fixture%3A%40%2F%3F%23%25:secret%3A%40%2F%3F%23%25%20word@host:8443"
        ] {
            let proxy = try AccountProxy.parse(input)
            #expect(proxy.username?.isEmpty == false && proxy.password?.isEmpty == false)
            #expect(try AccountProxy.parse(proxy.editableString) == proxy)
            #expect(proxy.displayName == proxy.urlString)
            #expect(String(describing: proxy) == proxy.urlString)
            #expect(String(reflecting: proxy) == proxy.urlString)
            #expect(!proxy.urlString.contains("fixture") && !proxy.urlString.contains("secret"))
        }
        let compact = try AccountProxy.parse("HOST:8080:fixture-user:fixture-pass")
        #expect(compact.scheme == .http && compact.host == "host" && compact.port == 8080)
        #expect(compact.username == "fixture-user" && compact.password == "fixture-pass")
        let special = try AccountProxy.parse("http://fixture%3A%40%2F%3F%23%25:secret%3A%40%2F%3F%23%25%20word@host:80")
        #expect(special.username == "fixture:@/?#%")
        #expect(special.password == "secret:@/?#% word")
        #expect(try AccountProxy.parse("host:80").editableString == "http://host:80")
    }

    @Test func parserRejectsIncompleteCredentialsAndControlCharacters() {
        for input in [
            "host:80:fixture-user:", "host:80::fixture-pass", "host:80::",
            "http://fixture-user@host:80", "http://fixture-user:@host:80", "http://:fixture-pass@host:80",
            "http://fixture%00user:fixture-pass@host:80", "http://fixture-user:fixture%0D%0Apass@host:80",
            "http://%FF:%FF@host:80",
            "host:80:fixture-user:fixture\tpass", "host:80:fixture-user:fixture\npass",
            "host:80:fixture-user:fixture\u{7F}pass"
        ] {
            #expect(throws: ProxyStoreError.invalidProxy) { try AccountProxy.parse(input) }
        }
    }

    @Test func proxyDecoderAcceptsLegacyDataAndValidatesCredentials() throws {
        let legacy = Data(#"{"scheme":"http","host":"HOST","port":80}"#.utf8)
        let proxy = try JSONDecoder().decode(AccountProxy.self, from: legacy)
        #expect(proxy.host == "host" && proxy.username == nil && proxy.password == nil)
        let invalidCredentials: [[String: String]] = [
            ["username": "fixture-user"], ["password": "fixture-pass"],
            ["username": "", "password": "fixture-pass"], ["username": "fixture-user", "password": ""],
            ["username": "fixture\u{00}user", "password": "fixture-pass"],
            ["username": "fixture-user", "password": "fixture\npass"]
        ]
        for credentials in invalidCredentials {
            var json: [String: Any] = ["scheme": "http", "host": "host", "port": 80]
            credentials.forEach { json[$0.key] = $0.value }
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AccountProxy.self, from: data) }
        }
    }

    @Test func authenticatedEntriesPersistAndDeduplicateByCredentials() throws {
        let file = fileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ProxyStore(fileURL: file)
        #expect(try store.add(text: "host:80:fixture-user:fixture-pass\nhttp://fixture-user:fixture-pass@host:80\nhost:80:fixture-user:other-pass") == 2)
        #expect(Set(store.proxies.map(\.proxy)).count == 2)
        let entry = try #require(store.proxies.first)
        try store.update(id: entry.id, text: entry.proxy.editableString, label: "Saved", isEnabled: false)
        let reopened = ProxyStore(fileURL: file)
        try reopened.load()
        #expect(reopened.proxies == store.proxies)
        #expect(reopened.proxies.first?.proxy.username == "fixture-user")
        #expect(reopened.proxies.first?.proxy.password == "fixture-pass")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func newSettingsAreEmptyAndUserChangesPersistWithPrivatePermissions() throws {
        let file = fileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ProxyStore(fileURL: file)
        #expect(!store.isLoaded)
        try store.load()
        #expect(store.isLoaded)
        #expect(!store.isEnabled)
        #expect(store.proxies.isEmpty)
        #expect(store.sources.isEmpty)

        #expect(try store.add(text: "first.example:80\nsecond.example:81") == 2)
        #expect(store.proxies.allSatisfy { $0.check == nil && $0.isEnabled })
        try store.addSource(url: "https://example.com/list.txt")
        let removedID = try #require(store.proxies.first?.id)
        try store.remove(id: removedID)
        try store.setEnabled(true)

        let reopened = ProxyStore(fileURL: file)
        try reopened.load()
        #expect(reopened.isEnabled)
        #expect(reopened.proxies == store.proxies)
        #expect(reopened.sources == store.sources)
        #expect(!reopened.proxies.contains { $0.id == removedID })
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func missingSettingsPreserveEnabledRoutingForPreviouslyAssignedAccounts() throws {
        let file = fileURL()
        let store = ProxyStore(fileURL: file)
        try store.load(initiallyEnabled: true)
        #expect(store.isLoaded && store.isEnabled)
        let reopened = ProxyStore(fileURL: file)
        try reopened.load()
        #expect(reopened.isLoaded && reopened.isEnabled)
    }

    @Test func corruptFileKeepsStoreUnloadedAndPreservesExistingBytes() throws {
        let file = fileURL()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("corrupt proxy settings".utf8)
        try original.write(to: file)
        let store = ProxyStore(fileURL: file)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(!store.isLoaded)
        #expect(store.proxies.isEmpty)
        #expect(store.sources.isEmpty)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func editsDeduplicateResetChecksAndDoNotPublishFailedWrites() async throws {
        let store = ProxyStore(fileURL: fileURL(), checker: { _ in Self.result(.available) })
        #expect(try store.add(text: "host:80\nhttp://host:80\nsocks4://host:80\nother:81", label: " BR ") == 2)
        let entry = try #require(store.proxies.first)
        await store.check(id: entry.id)
        #expect(store.proxies.first?.check?.status == .available)
        try store.update(id: entry.id, text: "new-host:80", label: "New", isEnabled: false)
        #expect(store.proxies.first?.check == nil)
        #expect(store.proxies.first?.isEnabled == false)
        #expect(throws: ProxyStoreError.duplicateProxy) {
            try store.update(id: entry.id, text: "other:81", label: "", isEnabled: true)
        }
        let before = store.proxies
        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data("block directory".utf8).write(to: directory)
        #expect(throws: (any Error).self) { try store.remove(id: entry.id) }
        #expect(store.proxies == before)
    }

    @Test func sourceRefreshMergesWithoutOverwritingEditsAndRejectsUntrustedURLs() async throws {
        let store = ProxyStore(fileURL: fileURL(), sourceLoader: { _ in
            "http://old-host:80\nsocks5://new-host:1080\nsocks4://unsupported:1080\nmalformed"
        })
        try store.add(text: "old-host:80", label: "My label")
        let entry = try #require(store.proxies.first)
        try store.update(id: entry.id, text: entry.proxy.urlString, label: entry.label, isEnabled: false)
        for invalid in ["http://example.com/list.txt", "https://user:pass@example.com/list", "https://example.com/list#fragment"] {
            #expect(throws: ProxyStoreError.invalidSource) { try store.addSource(url: invalid) }
        }
        try store.addSource(url: "https://example.com/list.txt")
        #expect(try await store.refreshSources() == 1)
        #expect(store.proxies.count == 2)
        #expect(store.proxies[0].id == entry.id && !store.proxies[0].isEnabled && store.proxies[0].label == "My label")
        #expect(store.status?.contains("Пропущено строк: 2") == true)
        #expect(try await store.refreshSources() == 0)
    }

    @Test func failedSourceRefreshLeavesExistingListIntact() async throws {
        let store = ProxyStore(fileURL: fileURL(), sourceLoader: { _ in "<html>not a list</html>" })
        try store.add(text: "host:80")
        try store.addSource(url: "https://example.com/list")
        let original = store.proxies
        await #expect(throws: (any Error).self) { try await store.refreshSources() }
        #expect(store.proxies == original)
        #expect(!store.isRefreshing)
    }

    @Test func disabledModeDoesNotProbeAndEnabledFailureNeverReturnsDirectConnection() async throws {
        let recorder = ProbeRecorder()
        let store = ProxyStore(fileURL: fileURL(), checker: { proxy in await recorder.probe(proxy) }, shuffled: { $0 })
        try store.add(text: "host:80\nother:81")
        #expect(try await store.chooseForNewAccount() == nil)
        #expect(await recorder.seen.isEmpty)
        try store.setEnabled(true)
        await #expect(throws: ProxyStoreError.noAvailableProxy) { try await store.chooseForNewAccount() }
        #expect(await recorder.seen.count == 2)
        #expect(store.proxies.allSatisfy { $0.check?.status == .unavailable })
        #expect(!store.isChecking)
    }

    @Test func selectionRechecksCachedSuccessThenUsesNextWorkingEnabledEndpoint() async throws {
        let recorder = ProbeRecorder(workingHost: "first")
        let store = ProxyStore(fileURL: fileURL(), checker: { proxy in await recorder.probe(proxy) }, shuffled: { $0 })
        try store.add(text: "first:80\nsecond:80\ndisabled:80")
        let disabled = try #require(store.proxies.last)
        try store.update(id: disabled.id, text: disabled.proxy.urlString, label: "", isEnabled: false)
        await store.checkAll()
        await recorder.setWorkingHost("second")
        try store.setEnabled(true)
        #expect(try await store.chooseForNewAccount()?.host == "second")
        let seen = await recorder.seen
        #expect(seen.suffix(2).map(\.host) == ["first", "second"])
        #expect(seen.filter { $0.host == "disabled" }.count == 1)
        #expect(store.proxies.first?.check?.status == .unavailable)
    }

    @Test func selectionBoundsUnavailableCandidateProbes() async throws {
        let recorder = ProbeRecorder()
        let store = ProxyStore(fileURL: fileURL(), checker: { proxy in await recorder.probe(proxy) }, shuffled: { $0 })
        try store.add(text: (1...20).map { "host\($0):80" }.joined(separator: "\n"))
        try store.setEnabled(true)
        await #expect(throws: ProxyStoreError.noAvailableProxy) { try await store.chooseForNewAccount() }
        #expect(await recorder.seen.count == 12)
    }

    nonisolated private static func result(_ status: ProxyCheckResult.Status) -> ProxyCheckResult {
        .init(status: status, latencyMilliseconds: status == .available ? 12 : nil,
              exitIP: status == .available ? "203.0.113.1" : nil, checkedAt: Date(), message: "fixture")
    }

    private actor ProbeRecorder {
        var seen: [AccountProxy] = []
        var workingHost: String?
        init(workingHost: String? = nil) { self.workingHost = workingHost }
        func setWorkingHost(_ host: String) { workingHost = host }
        func probe(_ proxy: AccountProxy) -> ProxyCheckResult {
            seen.append(proxy)
            return ProxyStoreTests.result(proxy.host == workingHost ? .available : .unavailable)
        }
    }
}
