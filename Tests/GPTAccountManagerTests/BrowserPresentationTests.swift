import AppKit
import Observation
import SwiftUI
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Observable
private final class PresentedBrowser {
    var session: BrowserSession
    init(session: BrowserSession) { self.session = session }
}

@MainActor
private struct BrowserHostFixture: View {
    let model: PresentedBrowser
    var body: some View { BrowserView(session: model.session) }
}

@MainActor
private struct BatchBrowserHostFixture: View {
    let store: AccountStore
    let coordinator: OperationCoordinator

    var body: some View {
        ZStack {
            if let id = store.selectedID, let session = coordinator.browserSession(for: id) {
                BrowserView(session: session)
            } else {
                Text("Group selected")
            }
            BackgroundBrowserPool(mounts: backgroundMounts)
        }
    }

    private var backgroundMounts: [BrowserMount] {
        let rotationIDs = coordinator.activeRotationAccountIDs.union(coordinator.pausedRotationAccountIDs)
        return store.accounts.compactMap { account in
            guard rotationIDs.contains(account.id),
                  account.id != store.selectedID,
                  let session = coordinator.browserSession(for: account.id)
            else { return nil }
            return BrowserMount(id: account.id, session: session)
        }
    }
}

@MainActor
private final class LocalBatchChecker: SubscriptionChecking {
    var activeSession: BrowserSession? { nil }

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        .failure("Unexpected separate subscription check")
    }
}

/// Keeps the real session preparation, presentation and OTP input. Only the
/// remote account operation is replaced with an entirely local HTML form.
@MainActor
private final class LocalMFABatchRotator: TwoFARotating {
    private let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
    var maximumConcurrentRotations: Int { 3 }
    private var active = 0
    private(set) var maximumActive = 0
    var pauseAfterDisabling = false

    func prepareBrowserSession(for account: AccountRecord) {
        browser.prepareBrowserSession(for: account)
    }

    func browserSession(for account: AccountRecord) -> BrowserSession? {
        browser.browserSession(for: account)
    }

    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        guard let session = browserSession(for: account) else {
            return .failure(stage: nil, message: "Missing test session")
        }
        session.webView.navigationDelegate = nil
        session.setVisible(true)
        session.webView.loadHTMLString(
            """
            <a id="before" href="#">Fixture</a>
            <form id="mfa"><input id="code"><button>Continue</button></form>
            <script>
              document.querySelector('#mfa').addEventListener('submit', event => {
                event.preventDefault();
                document.body.dataset.submitted = document.querySelector('#code').value;
              });
            </script>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/fixture")!)
        let expectedCode: String
        switch account.email {
        case "batch0@example.com": expectedCode = "100001"
        case "batch1@example.com": expectedCode = "200002"
        case "batch2@example.com": expectedCode = "300003"
        default: expectedCode = "999999"
        }
        guard await session.waitUntilAttached(seconds: 1) else {
            return .manualActionRequired(stage: nil, message: "MFA browser is not mounted")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.webView.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        do {
            _ = try await session.evaluate("document.querySelector('#before').focus()")
            let submittedByKeyboard = await session.submitMFAUsingKeyboard(expectedCode)
            var submittedValue: String?
            for _ in 0..<10 {
                submittedValue = try await session.evaluate(
                    "document.body.dataset.submitted || null") as? String
                if submittedValue != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard submittedByKeyboard, submittedValue == expectedCode
            else {
                return .manualActionRequired(stage: nil, message: "MFA field lost keyboard focus")
            }
            try onCheckpoint(.removalStarted)
            if pauseAfterDisabling {
                try onCheckpoint(.oldMethodDisabled)
                return .manualActionRequired(stage: .oldMethodDisabled, message: "Keep current session")
            }
            try onCheckpoint(.secretCaptured("MFRGGZDFMZTWQ2LK"))
            try onCheckpoint(.setupConfirmed)
            return .success(
                snapshot: .init(
                    signedInEmail: account.email,
                    planLabel: "plus",
                    activeUntil: Date(timeIntervalSince1970: 1_790_000_000),
                    willRenew: true),
                proof: .init(
                    passwordSubmitted: true,
                    pendingOTPSubmitted: true,
                    authenticatedImmediatelyAfterPendingOTP: true))
        } catch {
            return .failure(stage: nil, message: "Local fixture failed")
        }
    }
}

@MainActor
@Suite(.serialized)
struct BrowserPresentationTests {
    @Test func automationAllowsOnlyOneRotation() {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        #expect(automation.maximumConcurrentRotations == 1)
    }

    @Test(arguments: [2, 3])
    func groupRotationMountsOneBrowserAndCompletesEachAccountBeforeNext(concurrency: Int) async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: file)
        try store.merge((0..<3).map { index in
            .init(email: "batch\(index)@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP")
        })
        let group = try store.createGroup(name: "Fixture group", tag: nil)
        try store.moveAccounts(ids: Set(store.accounts.map(\.id)), to: group.id, protectedIDs: [])
        store.selectedID = nil // Selecting a category hides the account browser.
        let rotator = LocalMFABatchRotator()
        let coordinator = OperationCoordinator(
            store: store,
            checker: LocalBatchChecker(),
            rotator: rotator)
        let host = NSHostingView(rootView: BatchBrowserHostFixture(store: store, coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()

        await coordinator.rotate2FA(groupID: group.id, concurrency: concurrency)

        #expect(rotator.maximumActive == 1)
        #expect(coordinator.rotationStates.count == 3)
        #expect(coordinator.rotationStates.values.allSatisfy { $0 == .complete })
        #expect(coordinator.pausedRotationAccountIDs.isEmpty)
        #expect(!coordinator.isRunning)
        #expect(store.selectedID == store.accounts.last?.id)
        for account in store.accounts {
            #expect(account.totpSecret == "MFRGGZDFMZTWQ2LK")
            #expect(account.pendingTOTPSecret == nil)
            #expect(account.rotationStage == nil)
            #expect(account.planLabel == "plus")
            #expect(account.subscriptionDate == Date(timeIntervalSince1970: 1_790_000_000))
        }
    }

    @Test func pausedGroupKeepsOriginalBrowserMountedWhenAccountIsNotSelected() async throws {
        _ = NSApplication.shared
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        try store.merge((0..<2).map { .init(email: "batch\($0)@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP") })
        let rotator = LocalMFABatchRotator()
        rotator.pauseAfterDisabling = true
        let coordinator = OperationCoordinator(store: store, checker: LocalBatchChecker(), rotator: rotator)
        let host = NSHostingView(rootView: BatchBrowserHostFixture(store: store, coordinator: coordinator))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        await coordinator.rotate2FA(accountIDs: store.accounts.map(\.id), concurrency: 3)
        let first = store.accounts[0]
        let original = try #require(coordinator.browserSession(for: first.id))
        let webView = original.webView
        #expect(first.rotationStage == .oldMethodDisabled)
        #expect(coordinator.browserSession(for: store.accounts[1].id) == nil)
        #expect(!coordinator.isRotating)
        store.selectedID = nil
        await settle { webView.window === window }
        #expect(coordinator.browserSession(for: first.id) === original)
        #expect(original.webView === webView)
        #expect(await original.waitUntilAttached(seconds: 1))
        #expect(try await original.evaluate("document.body.dataset.submitted") as? String == "100001")
        #expect(coordinator.rotationStates[store.accounts[1].id] == .queued)
    }

    @Test func replacingSessionMountsTheNewWebViewAndDetachesTheOldOne() async throws {
        _ = NSApplication.shared
        let first = BrowserSession(dataStore: .nonPersistent())
        let replacement = BrowserSession(dataStore: .nonPersistent())
        let model = PresentedBrowser(session: first)
        let host = NSHostingView(rootView: BrowserHostFixture(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        await settle { first.webView.window === window }
        try #require(first.webView.window === window)

        model.session = replacement
        await settle { replacement.webView.window === window }

        #expect(replacement.webView.window === window)
        #expect(first.webView.superview == nil)
        #expect(replacement.webView.bounds.width > 0)
        #expect(replacement.webView.bounds.height > 0)
    }

    @Test func sessionCanWaitUntilItsWebViewIsAttached() async {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        let host = NSHostingView(rootView: BrowserView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        #expect(await session.waitUntilAttached(seconds: 1))
    }

    @Test func backgroundBrowserPoolMountsEveryConcurrentSession() async throws {
        _ = NSApplication.shared
        let sessions = (0..<3).map { _ in
            BrowserSession(dataStore: .nonPersistent())
        }
        let mounts = sessions.map { session in
            BrowserMount(id: UUID(), session: session)
        }
        let host = NSHostingView(rootView: BackgroundBrowserPool(mounts: mounts))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        for session in sessions {
            #expect(await session.waitUntilAttached(seconds: 1))
            #expect(session.webView.window === window)
        }
    }

    @Test func browserSessionTimesOutAnUnresolvedJavaScriptCall() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(
            "<html><body>fixture</body></html>",
            baseURL: URL(string: "https://chatgpt.com/")!)
        await settle { !session.webView.isLoading }

        do {
            _ = try await session.evaluate(
                "new Promise(() => {})",
                timeout: .milliseconds(100))
            Issue.record("Unresolved JavaScript call did not time out")
        } catch BrowserSessionError.evaluationTimedOut {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cancellingBrowserLoadingReleasesJavaScriptWait() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(
            "<html><body>fixture</body></html>",
            baseURL: URL(string: "https://chatgpt.com/")!)
        await settle { !session.webView.isLoading }

        let task = Task { () -> Bool in
            do {
                _ = try await session.evaluate(
                    "new Promise(() => {})",
                    timeout: .seconds(2))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        session.cancelLoading()

        #expect(await task.value)
    }

    @Test func cancellingBrowserLoadingReleasesNavigationWait() async {
        let session = BrowserSession(dataStore: .nonPersistent())
        let navigation = session.load(URL(string: "https://chatgpt.com/")!)
        session.cancelLoading()

        #expect(!(await session.waitForNavigation(navigation, seconds: 1)))
    }

    @Test func keyboardMFASubmissionSubmitsCompleteValueBeforePressingContinue() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(
            """
            <html><body>
              <a id="before" href="#">OpenAI</a>
              <form id="mfa">
                <label for="code">Одноразовый код</label>
                <input id="code" aria-label="Одноразовый код">
                <button id="continue" type="submit">Продолжить</button>
              </form>
              <script>
                document.querySelector('#code').addEventListener('input', event => {
                  document.body.dataset.inputValue = event.target.value;
                });
                document.querySelector('#mfa').addEventListener('submit', event => {
                  event.preventDefault();
                  document.body.dataset.submitted = document.querySelector('#code').value;
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let host = NSHostingView(rootView: BrowserView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        session.setVisible(true)
        host.layoutSubtreeIfNeeded()
        await settle { !session.webView.isLoading && session.webView.window === window }
        _ = try await session.evaluate("document.querySelector('#before').focus()")

        #expect(await session.submitMFAUsingKeyboard("123456"))
        let fieldValue = try await session.evaluate(
            "document.querySelector('#code').value")
        let submitted = try await session.evaluate(
            "document.body.dataset.submitted || null")
        let inputValue = try await session.evaluate(
            "document.body.dataset.inputValue || null")
        #expect(fieldValue as? String == "123456")
        #expect(submitted as? String == "123456")
        #expect(inputValue as? String == "123456")
    }

    @Test func creatingActiveSessionInvalidatesThePresentationLookup() async {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let account = AccountRecord(credential: .init(
            email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))

        await confirmation("The UI must be notified when the active session changes") { changed in
            withObservationTracking {
                _ = automation.browserSession(for: account)
            } onChange: {
                changed()
            }
            automation.prepareBrowserSession(for: account)
        }
    }

    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    @Test func stalledBrowserRecoveryControlsCanBeHosted() {
        _ = NSApplication.shared
        let availability = BrowserRecoveryAvailability(
            canReload: true,
            reopenDestination: .security,
            freshLoginMode: .manualFactor,
            canReturnToOriginalSession: true,
            warning: "Старый 2FA уже мог быть отключён.")
        let host = NSHostingView(rootView: BrowserRecoveryControlsView(
            availability: availability,
            onReload: {},
            onReopen: {},
            onFreshLogin: {},
            onReturnToOriginal: {}))

        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height > 0)
    }

}
