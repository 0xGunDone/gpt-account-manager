import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct RegistrationMailScreenTransitionTests {
    private let email = "fixture@example.com"

    private func coordinator() -> RegistrationCoordinator {
        _ = NSApplication.shared
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        return RegistrationCoordinator(store: store, browser: ChatGPTAutomation(sessionManager: WebSessionManager()),
                                       mailbox: MailRuMailbox(expectedMailbox: "fixture@mail.ru"))
    }

    private var codeForm: String {
        """
        <main><p>Code sent to \(email)</p><form onsubmit="event.preventDefault();document.body.dataset.submits='yes'">
        <input name="code" autocomplete="one-time-code"><button>Continue</button>
        <button type="button" onclick="document.body.dataset.resent='yes'">Resend email</button></form></main>
        """
    }

    private func fixture() async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        session.webView.navigationDelegate = nil
        try await load(codeForm, in: session)
        return session
    }

    private func load(_ html: String, in session: BrowserSession) async throws {
        session.webView.loadHTMLString(html, baseURL: URL(string: "https://auth.openai.com/email-verification"))
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        try #require(!session.webView.isLoading)
    }

    @Test(arguments: ["/about-you", "/mfa-challenge/fixture", "/email-verification"])
    func changedScreenCancelsPendingReadAndReturnsForInspection(path: String) async throws {
        let coordinator = coordinator()
        let session = try await fixture()
        var reading = false
        var readEnded = false
        var reads = 0
        let waiting = Task {
            try await coordinator.waitForEmailCode(in: session, expectedEmail: email) {
                reads += 1
                reading = true
                defer { readEnded = true }
                try await Task.sleep(for: .seconds(30))
                return MailVerificationCode(messageID: "late", code: "123456")
            }
        }
        defer { waiting.cancel(); session.cancelLoading() }
        for _ in 0..<100 where !reading { try await Task.sleep(for: .milliseconds(20)) }
        try #require(reading)
        let encodedPath = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
        _ = try await session.evaluate("(() => { history.replaceState({}, '', \(encodedPath)); document.body.innerHTML='<h1>Verify you are human</h1>'; return true; })()")
        #expect(try await waiting.value == nil)
        #expect(readEnded && reads == 1)
        #expect(try await session.evaluate("document.querySelector('input') === null") as? Bool == true)
    }

    @Test func replacementDocumentAtSameURLCancelsPendingRead() async throws {
        let coordinator = coordinator()
        let session = try await fixture()
        var reading = false
        var readEnded = false
        let waiting = Task {
            try await coordinator.waitForEmailCode(in: session, expectedEmail: email) {
                reading = true
                defer { readEnded = true }
                try await Task.sleep(for: .seconds(30))
                return MailVerificationCode(messageID: "late", code: "123456")
            }
        }
        defer { waiting.cancel(); session.cancelLoading() }
        for _ in 0..<100 where !reading { try await Task.sleep(for: .milliseconds(20)) }
        try #require(reading)
        try await load(codeForm, in: session)
        #expect(try await waiting.value == nil)
        #expect(readEnded)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func alreadyChangedScreenNeverStartsMailRead() async throws {
        let coordinator = coordinator()
        let session = try await fixture()
        _ = try await session.evaluate("(() => { document.body.innerHTML='<h1>Verify you are human</h1>'; return true; })()")
        var reads = 0
        let code = try await coordinator.waitForEmailCode(in: session, expectedEmail: email) {
            reads += 1
            return MailVerificationCode(messageID: "unused", code: "123456")
        }
        #expect(code == nil && reads == 0)
    }

    @Test func codeArrivingAfterTransitionIsDiscarded() async throws {
        let coordinator = coordinator()
        let session = try await fixture()
        let code = try await coordinator.waitForEmailCode(in: session, expectedEmail: email) {
            _ = try await session.evaluate("(() => { history.replaceState({}, '', '/about-you'); document.body.innerHTML='<h1>Profile</h1>'; return true; })()")
            return MailVerificationCode(messageID: "stale", code: "123456")
        }
        #expect(code == nil)
    }

    @Test func cancellationJoinsPendingRead() async throws {
        let coordinator = coordinator()
        let session = try await fixture()
        var reading = false
        var readEnded = false
        let waiting = Task {
            try await coordinator.waitForEmailCode(in: session, expectedEmail: email) {
                reading = true
                defer { readEnded = true }
                try await Task.sleep(for: .seconds(30))
                return MailVerificationCode(messageID: "unused", code: "123456")
            }
        }
        for _ in 0..<100 where !reading { try await Task.sleep(for: .milliseconds(20)) }
        try #require(reading)
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(readEnded)
    }

    @Test func wrongDestinationFailsBeforeReadingMail() async throws {
        let coordinator = coordinator()
        let session = try await fixture()
        var reads = 0
        await #expect(throws: (any Error).self) {
            try await coordinator.waitForEmailCode(in: session, expectedEmail: "other@example.com") {
                reads += 1
                return MailVerificationCode(messageID: "unused", code: "123456")
            }
        }
        #expect(reads == 0)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.resent === undefined") as? Bool == true)
    }

    @Test func matchingCodeReturnsWithoutSubmittingOrResending() async throws {
        let coordinator = coordinator()
        let session = try await fixture()
        let expected = MailVerificationCode(messageID: "fresh", code: "123456")
        let code = try await coordinator.waitForEmailCode(in: session, expectedEmail: email) { expected }
        #expect(code == expected)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.submits === undefined && document.body.dataset.resent === undefined") as? Bool == true)
    }

    @Test(arguments: [false, true])
    func observedMailCodeCannotReachReplacementForm(replaceForm: Bool) async throws {
        let coordinator = coordinator()
        let session = try await fixture()
        let code = try #require(try await coordinator.waitForEmailCode(in: session, expectedEmail: email) {
            MailVerificationCode(messageID: "fresh", code: "123456")
        })
        if replaceForm {
            _ = try await session.evaluate("(() => { const old=document.querySelector('form'); old.replaceWith(old.cloneNode(true)); return true; })()")
        }
        let submitted = try await RegistrationForm.submitEmailCode(code.code, expectedEmail: email,
                                                                   observedScreenOnly: true, in: session)
        #expect(submitted == !replaceForm)
        if replaceForm {
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
            #expect(try await session.evaluate("document.body.dataset.submits === undefined && document.body.dataset.resent === undefined") as? Bool == true)
        }
    }

    @Test func signInResumesScreenInspectionAfterManualEmailCompletion() async throws {
        let coordinator = coordinator()
        let session = try await fixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let account = AccountRecord(credential: .init(email: email, password: "fixture-password", totpSecret: ""))
        var reading = false
        var readEnded = false
        var handlers = 0
        let login = Task {
            await browser.signIn(account: account, secret: "", in: session,
                initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
                loginTimeoutSeconds: 3, automaticallyWaitForTransitions: true,
                emailCodeHandler: { page in
                    handlers += 1
                    let code = try await coordinator.waitForEmailCode(in: page, expectedEmail: email) {
                        reading = true
                        defer { readEnded = true }
                        try await Task.sleep(for: .seconds(30))
                        return MailVerificationCode(messageID: "late", code: "123456")
                    }
                    return code != nil
                })
        }
        defer { login.cancel(); session.cancelLoading() }
        for _ in 0..<100 where !reading { try await Task.sleep(for: .milliseconds(20)) }
        try #require(reading)
        session.webView.loadHTMLString("""
        <h1>ChatGPT</h1><script>
        window.fetch=async()=>({ok:true,json:async()=>({user:{email:'fixture@example.com',id:'fixture-user'}})});
        </script>
        """, baseURL: URL(string: "https://chatgpt.com/"))
        let result = await login.value
        guard case .success(let snapshot, _) = result else {
            Issue.record("Manual email completion must resume sign-in inspection, not pause for a code")
            return
        }
        #expect(snapshot.signedInEmail == email)
        #expect(readEnded && handlers == 1)
    }
}
