import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite struct WebSessionManagerTests {
    @Test func cachesPerAccountAndSeparatesAccounts() {
        let manager = WebSessionManager()
        let first = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let second = AccountRecord(credential: .init(
            email: "two@example.com", password: "pw", totpSecret: "KRUGS4ZANFZSAYJA"))

        #expect(manager.session(for: first) === manager.session(for: first))
        #expect(manager.session(for: first) !== manager.session(for: second))
        #expect(first.browserStoreID != second.browserStoreID)
    }

    @Test func subscriptionCheckKeepsPersistentAccountSessionAfterCompletion() {
        let manager = WebSessionManager()
        let account = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: manager)
        let persistent = manager.session(for: account)

        let first = automation.subscriptionCheckSession(for: account)
        let resumed = automation.subscriptionCheckSession(for: account)
        automation.finishSubscriptionCheck(accountID: account.id)
        let next = automation.subscriptionCheckSession(for: account)

        #expect(first === persistent)
        #expect(resumed === first)
        #expect(next === first)
    }

    @Test func recheckingAnAccountReusesItsOwnSession() {
        let manager = WebSessionManager()
        let account = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: manager)

        let first = automation.newSubscriptionCheckSession(for: account)
        first.setVisible(true)
        let continued = automation.subscriptionCheckSession(for: account)
        let next = automation.newSubscriptionCheckSession(for: account)

        #expect(continued === first)
        #expect(next === first)
        #expect(!first.isVisible)
    }

    @Test func checkingAnotherAccountKeepsPreviousCookiesAndCleanLoginRemainsIsolated() async throws {
        let manager = WebSessionManager()
        let automation = ChatGPTAutomation(sessionManager: manager)
        let first = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let second = AccountRecord(credential: .init(
            email: "two@example.com", password: "pw", totpSecret: "KRUGS4ZANFZSAYJA"))
        let session = automation.newSubscriptionCheckSession(for: first)
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "auth.openai.com", .path: "/", .name: "fixture_session", .value: "one",
            .secure: "TRUE", .expires: Date().addingTimeInterval(600),
        ]))
        await session.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let other = automation.newSubscriptionCheckSession(for: second)
        let again = automation.newSubscriptionCheckSession(for: first)
        #expect(again === session)
        #expect(again.webView.configuration.websiteDataStore.isPersistent)
        #expect(await again.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .contains { $0.name == "fixture_session" })
        #expect(await other.webView.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty)
        let clean = automation.cleanLoginSession(for: first)
        #expect(!clean.webView.configuration.websiteDataStore.isPersistent)
        #expect(await clean.webView.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty)
        await session.webView.configuration.websiteDataStore.httpCookieStore.deleteCookie(cookie)
    }

    @Test func changingLoginCreatesADifferentCookieStore() {
        let manager = WebSessionManager()
        var account = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let first = manager.session(for: account)
        account.email = "two@example.com"
        account.browserStoreID = UUID()
        let second = manager.session(for: account)
        #expect(first !== second)
        #expect(first.webView.configuration.websiteDataStore !== second.webView.configuration.websiteDataStore)
    }

    @Test func freshLoginClearsOnlyTheChosenAccountCookies() async throws {
        let manager = WebSessionManager()
        let automation = ChatGPTAutomation(sessionManager: manager)
        let first = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let second = AccountRecord(credential: .init(
            email: "two@example.com", password: "pw", totpSecret: "KRUGS4ZANFZSAYJA"))
        let original = automation.subscriptionCheckSession(for: first)
        let other = automation.subscriptionCheckSession(for: second)
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "auth.openai.com", .path: "/", .name: "fixture_session", .value: "test",
            .secure: "TRUE", .expires: Date().addingTimeInterval(600),
        ]))
        await original.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        await other.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        _ = await automation.startFreshLogin(for: first, context: .subscriptionCheck)
        let replaced = automation.subscriptionCheckSession(for: first)
        #expect(replaced !== original)
        #expect(await replaced.webView.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty)
        #expect(await other.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .contains { $0.name == "fixture_session" })
        await other.webView.configuration.websiteDataStore.httpCookieStore.deleteCookie(cookie)
    }

    @Test func twoFARotationUsesSavedSessionAndPreservesItForRecovery() {
        let manager = WebSessionManager()
        let account = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: manager)
        let persistent = manager.session(for: account)

        let first = automation.twoFARotationSession(for: account)
        var recovering = account
        recovering.rotationStage = .removingOldMethod
        let resumed = automation.twoFARotationSession(for: recovering)
        let next = automation.twoFARotationSession(for: account)

        #expect(first === persistent)
        #expect(resumed === first)
        #expect(next === persistent)
    }

    @Test func preparedRotationSessionIsTheSessionMountedBeforeAutomationStarts() {
        let manager = WebSessionManager()
        let account = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: manager)

        automation.prepareBrowserSession(for: account)
        let mounted = automation.browserSession(for: account)
        let used = automation.twoFARotationSession(for: account)

        #expect(mounted === used)
        #expect(used === manager.session(for: account))
    }

    @Test func visibleRotationSessionIsReusedAfterAChallengePauseBeforeCheckpoint() {
        let manager = WebSessionManager()
        let account = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: manager)

        let first = automation.twoFARotationSession(for: account)
        first.setVisible(true)
        automation.prepareBrowserSession(for: account)
        let resumed = automation.twoFARotationSession(for: account)

        #expect(resumed === first)
    }

    @Test func stagedRecoveryWithoutPinnedSessionIsMarkedUnavailable() {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var recovering = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        recovering.rotationStage = .oldMethodDisabled

        _ = automation.twoFARotationSession(for: recovering)

        #expect(automation.rotationRecoverySessionState(for: recovering) == .unavailable)
    }

    @Test func stagedRecoveryRetainsThePinnedSessionFromTheOriginalRun() {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let account = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        let original = automation.twoFARotationSession(for: account)
        var recovering = account
        recovering.rotationStage = .oldMethodDisabled

        let resumed = automation.twoFARotationSession(for: recovering)

        #expect(resumed === original)
        #expect(automation.rotationRecoverySessionState(for: recovering) == .authenticated)
    }

    @Test func rejectsUntrustedTopLevelNavigationBeforeItCanLoadDOM() async throws {
        let session = BrowserSession(dataStoreID: UUID())
        session.load(URL(string: "data:text/html,<input%20type='password'>")!)

        try await Task.sleep(for: .milliseconds(500))

        #expect(session.webView.url == nil)
    }

    @Test func rejectsHTTPSHostsOutsideOpenAIAllowlist() async throws {
        let session = BrowserSession(dataStoreID: UUID())
        session.load(URL(string: "https://example.com/")!)

        try await Task.sleep(for: .seconds(1))

        #expect(session.webView.url == nil)
    }

    @Test func authenticationRejectsUnrelatedOpenAISubdomains() {
        #expect(!TrustedChatGPTOrigin.allowsAuthentication(
            URL(string: "https://staging.openai.com/login")))
        #expect(TrustedChatGPTOrigin.allowsAuthentication(
            URL(string: "https://auth.openai.com/login")))
        #expect(TrustedChatGPTOrigin.allowsAuthentication(
            URL(string: "https://chatgpt.com/")))
    }

    @Test func injectedVerificationFactoryCreatesDistinctSessions() {
        var created: [BrowserSession] = []
        let manager = WebSessionManager(verificationSessionFactory: {
            let session = BrowserSession(dataStore: .nonPersistent())
            created.append(session)
            return session
        })

        let first = manager.verificationSession()
        let second = manager.verificationSession()

        #expect(first !== second)
        #expect(created.count == 2)
    }


    @Test func freshPreRotationLoginReplacesOnlyTheRotationSession() async throws {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let account = AccountRecord(credential: .init(
            email: "one@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        automation.prepareBrowserSession(for: account)
        let original = automation.browserSession(for: account)

        let result = await automation.startFreshLogin(
            for: account,
            context: .rotation(stage: nil))

        guard case .readyToContinue = result else {
            Issue.record("Expected a prepared fresh rotation login")
            return
        }
        #expect(automation.browserSession(for: account) !== original)
        #expect(!automation.hasCandidateSession(for: account.id))
    }

    @Test func cleanLoginResetKeepsPendingStateAndReplacesOnlyVerificationSession() async throws {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var account = AccountRecord(credential: .init(
            email: "one@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
        account.rotationStage = .awaitingCleanLogin
        let original = automation.cleanLoginSession(for: account)

        let result = await automation.startFreshLogin(
            for: account,
            context: .rotation(stage: .awaitingCleanLogin))

        guard case .readyToContinue = result else {
            Issue.record("Expected a fresh clean-login session")
            return
        }
        #expect(automation.cleanLoginSession(for: account) !== original)
        #expect(account.pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(account.rotationStage == .awaitingCleanLogin)
    }

    @Test func riskyFreshLoginRetainsAnOriginalSessionToReturnTo() async throws {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var account = AccountRecord(credential: .init(
            email: "one@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        account.rotationStage = .oldMethodDisabled
        automation.prepareBrowserSession(for: account)
        let original = automation.browserSession(for: account)

        _ = await automation.startFreshLogin(
            for: account,
            context: .rotation(stage: .oldMethodDisabled))
        let candidate = automation.recoverySession(
            for: account,
            context: .rotation(stage: .oldMethodDisabled))

        #expect(automation.hasCandidateSession(for: account.id))
        #expect(candidate !== original)
        #expect(automation.browserSession(for: account) === candidate)

        automation.returnToOriginalSession(for: account)

        #expect(!automation.hasCandidateSession(for: account.id))
        #expect(automation.recoverySession(
            for: account,
            context: .rotation(stage: .oldMethodDisabled)) === original)
    }


    @Test func staleFreshLoginContextCannotAuthorizeTheOldSecret() async {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var account = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        account.rotationStage = .oldMethodDisabled
        let outcome = await automation.startFreshLogin(for: account, context: .rotation(stage: nil))
        guard case .failure = outcome else {
            Issue.record("A stale confirmation must not authorize the old secret")
            return
        }
    }

    @Test func manualSetupThenCleanLoginDoesNotReuseTheCandidate() async throws {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var account = AccountRecord(credential: .init(
            email: "one@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        account.rotationStage = .oldMethodDisabled
        automation.prepareBrowserSession(for: account)
        _ = await automation.startFreshLogin(for: account, context: .rotation(stage: .oldMethodDisabled))
        let candidate = automation.recoverySession(for: account, context: .rotation(stage: .oldMethodDisabled))
        try RotationState.stageManuallyConfiguredSecret("KRUGS4ZANFZSAYJA", in: &account)
        automation.prepareBrowserSession(for: account)
        let clean = automation.cleanLoginSession(for: account)
        #expect(!automation.hasCandidateSession(for: account.id))
        #expect(clean !== candidate)
        #expect(automation.browserSession(for: account) === clean)
        #expect(account.pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
    }

}
