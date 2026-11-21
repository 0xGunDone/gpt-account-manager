import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct OperationProxyFailoverTests {
    private let originalProxy = AccountProxy(scheme: .http, host: "original", port: 8080)
    private let replacementProxy = AccountProxy(scheme: .socks5, host: "replacement", port: 1080)

    private func fixture(workingHost: String?, held: Bool = false) throws -> (AccountStore, ProxyStore, Probe, Checker) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        try store.merge([.init(email: "fixture@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP")])
        try store.mutate(id: store.accounts[0].id) { $0.proxy = originalProxy }
        let probe = Probe(workingHost: workingHost, held: held)
        let proxies = ProxyStore(fileURL: directory.appendingPathComponent("proxies.json"),
            checker: { await probe.check($0) }, shuffled: { $0 })
        try proxies.add(text: "\(originalProxy.urlString)\n\(replacementProxy.urlString)")
        try proxies.setEnabled(true)
        return (store, proxies, probe, Checker(store: store))
    }

    @Test func healthyProxyStaysPinnedAndDisabledModeDoesNotProbe() async throws {
        let (store, proxies, probe, checker) = try fixture(workingHost: originalProxy.host)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = store.accounts[0]
        let coordinator = OperationCoordinator(store: store, checker: checker, proxyStore: proxies)

        await coordinator.check(id: original.id)
        #expect(await probe.seen == [originalProxy])
        #expect(checker.checked.map(\.proxy) == [originalProxy])
        #expect(store.accounts[0].proxy == originalProxy)
        #expect(store.accounts[0].browserStoreID == original.browserStoreID)
        try proxies.setEnabled(false)
        await coordinator.check(id: original.id)
        #expect(await probe.seen == [originalProxy])
        #expect(checker.checked.count == 2)
    }

    @Test func deadProxyIsPersistedBeforeCheckerStartsWithoutChangingIdentity() async throws {
        let (store, proxies, probe, checker) = try fixture(workingHost: replacementProxy.host)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = store.accounts[0]
        let coordinator = OperationCoordinator(store: store, checker: checker, proxyStore: proxies)

        await coordinator.check(id: original.id)

        #expect(await probe.seen == [originalProxy, replacementProxy])
        #expect(checker.checked.map(\.proxy) == [replacementProxy])
        #expect(checker.persistedProxies == [replacementProxy])
        #expect(store.accounts[0].proxy == replacementProxy)
        #expect(store.accounts[0].browserStoreID == original.browserStoreID)
        #expect(store.accounts[0].credentialLine == original.credentialLine)
        #expect(store.accounts[0].status == .ready)
    }

    @Test func unavailablePoolPausesWithoutCheckerOrDirectFallbackAndCanResume() async throws {
        let (store, proxies, probe, checker) = try fixture(workingHost: nil)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = store.accounts[0]
        let coordinator = OperationCoordinator(store: store, checker: checker, proxyStore: proxies)

        await coordinator.check(id: original.id)

        #expect(checker.checked.isEmpty && checker.continued.isEmpty)
        #expect(coordinator.pausedAccountID == original.id)
        #expect(!coordinator.isRunning)
        #expect(coordinator.completedCount == 0)
        #expect(coordinator.message?.contains("Рабочий прокси не найден") == true)
        #expect(store.accounts[0].status == .failed)
        #expect(store.accounts[0].proxy == originalProxy)
        #expect(store.accounts[0].lastCheckedAt == original.lastCheckedAt)
        await probe.setWorkingHost(replacementProxy.host)
        await coordinator.resume()
        #expect(checker.checked.map(\.proxy) == [replacementProxy])
        #expect(checker.continued.isEmpty)
        #expect(coordinator.pausedAccountID == nil)
        #expect(coordinator.completedCount == 1)
    }

    @Test(arguments: [false, true])
    func stoppedOrCancelledProbeDoesNotChangeAccountOrStartChecker(cancelTask: Bool) async throws {
        let (store, proxies, probe, checker) = try fixture(workingHost: replacementProxy.host, held: true)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = store.accounts[0]
        let coordinator = OperationCoordinator(store: store, checker: checker, proxyStore: proxies)
        let task = Task { await coordinator.check(id: original.id) }
        while !(await probe.isWaiting) { await Task.yield() }

        #expect(coordinator.isRunning)
        #expect(coordinator.protectedAccountIDs.contains(original.id))
        if cancelTask { task.cancel() } else { coordinator.stop() }
        await probe.release()
        await task.value

        #expect(store.accounts[0] == original)
        #expect(checker.checked.isEmpty && checker.continued.isEmpty)
        #expect(!coordinator.isRunning)
        #expect(coordinator.pausedAccountID == nil)
        #expect(coordinator.message == "Stopped")
    }

    @Test func stoppedFailingProbeDoesNotMarkAccountFailed() async throws {
        let (store, proxies, probe, checker) = try fixture(workingHost: nil, held: true)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = store.accounts[0]
        let coordinator = OperationCoordinator(store: store, checker: checker, proxyStore: proxies)
        let task = Task { await coordinator.check(id: original.id) }
        while !(await probe.isWaiting) { await Task.yield() }
        coordinator.stop()
        await probe.release()
        await task.value
        #expect(store.accounts[0] == original)
        #expect(coordinator.message == "Stopped")
        #expect(coordinator.pausedAccountID == nil)
    }

    @Test(arguments: [false, true])
    func pausedCheckUsesFreshSessionOnlyWhenProxyChanges(replace: Bool) async throws {
        let (store, proxies, probe, checker) = try fixture(workingHost: originalProxy.host)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = store.accounts[0]
        let coordinator = OperationCoordinator(store: store, checker: checker, proxyStore: proxies)
        checker.pauseNext = true
        await coordinator.check(id: original.id)
        #expect(coordinator.pausedAccountID == original.id)
        if replace { await probe.setWorkingHost(replacementProxy.host) }

        await coordinator.resume()

        #expect(checker.checked.count == (replace ? 2 : 1))
        #expect(checker.continued.count == (replace ? 0 : 1))
        #expect(store.accounts[0].proxy == (replace ? replacementProxy : originalProxy))
        #expect(store.accounts[0].status == .ready)
    }

    @Test func freshRotationReplacesProxyBeforeBrowserButRecoveryKeepsPinnedRoute() async throws {
        let (store, proxies, probe, checker) = try fixture(workingHost: replacementProxy.host)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let id = store.accounts[0].id
        let rotator = Rotator()
        let coordinator = OperationCoordinator(store: store, checker: checker, rotator: rotator, proxyStore: proxies)
        await coordinator.rotate2FA(id: id)
        #expect(rotator.prepared.allSatisfy { $0.proxy == replacementProxy })
        #expect(rotator.rotated.map(\.proxy) == [replacementProxy])
        #expect(store.accounts[0].proxy == replacementProxy)
        let probesBeforeRecovery = await probe.seen
        try store.mutate(id: id) { RotationState.markOldMethodDisabled(in: &$0) }
        await probe.setWorkingHost(nil)
        await coordinator.continueRotation(id: id)
        #expect(await probe.seen == probesBeforeRecovery)
        #expect(rotator.rotated.count == 2)
        #expect(rotator.rotated.last?.proxy == replacementProxy)
        #expect(store.accounts[0].rotationStage == .oldMethodDisabled)
    }

    private actor Probe {
        var seen: [AccountProxy] = []
        var isWaiting: Bool { continuation != nil }
        private var workingHost: String?
        private var held: Bool
        private var continuation: CheckedContinuation<Void, Never>?

        init(workingHost: String?, held: Bool) { self.workingHost = workingHost; self.held = held }
        func setWorkingHost(_ host: String?) { workingHost = host }
        func release() { held = false; continuation?.resume(); continuation = nil }
        func check(_ proxy: AccountProxy) async -> ProxyCheckResult {
            seen.append(proxy)
            if held { await withCheckedContinuation { continuation = $0 } }
            let available = proxy.host == workingHost
            return .init(status: available ? .available : .unavailable, latencyMilliseconds: nil,
                exitIP: nil, checkedAt: Date(), message: "fixture")
        }
    }

    @MainActor
    private final class Checker: SubscriptionChecking {
        var activeSession: BrowserSession? { nil }
        var checked: [AccountRecord] = []
        var continued: [AccountRecord] = []
        var persistedProxies: [AccountProxy?] = []
        var pauseNext = false
        private let store: AccountStore
        init(store: AccountStore) { self.store = store }
        func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
            checked.append(account)
            persistedProxies.append(store.accounts.first(where: { $0.id == account.id })?.proxy)
            return outcome(account)
        }
        func continueCheck(account: AccountRecord) async -> SubscriptionCheckOutcome {
            continued.append(account)
            return outcome(account)
        }
        private func outcome(_ account: AccountRecord) -> SubscriptionCheckOutcome {
            if pauseNext { pauseNext = false; return .manualActionRequired("Fixture challenge") }
            return .success(.init(signedInEmail: account.email, planLabel: "plus", activeUntil: nil, willRenew: nil))
        }
    }

    @MainActor
    private final class Rotator: TwoFARotating {
        var prepared: [AccountRecord] = []
        var rotated: [AccountRecord] = []
        func prepareBrowserSession(for account: AccountRecord) { prepared.append(account) }
        func rotate2FA(account: AccountRecord,
            onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void) async -> TwoFARotationOutcome {
            rotated.append(account)
            return .manualActionRequired(stage: account.rotationStage, message: "Fixture challenge")
        }
    }
}
