import Foundation

enum ExternalLoginMailError: LocalizedError {
    case baselineUnavailable, wrongRecipient, mailboxUnavailable, challengeChanged, submissionUnconfirmed

    var errorDescription: String? {
        switch self {
        case .baselineUnavailable:
            "Время запроса почтового кода не подтверждено. Введите код из письма в браузере."
        case .wrongRecipient:
            "OpenAI показывает другой адрес для почтового кода. Проверьте аккаунт в браузере."
        case .mailboxUnavailable:
            "Свежий код во внешней почте не получен. Проверьте почту и введите код в браузере."
        case .challengeChanged:
            "Форма почтового кода изменилась. Проверьте страницу OpenAI и продолжите в браузере."
        case .submissionUnconfirmed:
            "OpenAI ещё не подтвердил почтовый код. Проверьте страницу и продолжите в браузере."
        }
    }
}

/// Keeps mailbox freshness and submission evidence within one browser login attempt.
@MainActor
final class ExternalLoginMailRequest {
    private struct Request {
        let baseline: Set<String>
        let startedAt: Date
    }

    private let mailbox: any EmailCodeReceiving
    private let email: String
    private let generation: Int
    private var prepared: (pageURL: URL, baseline: Set<String>?, capturedAt: ContinuousClock.Instant)?
    private var request: Request?
    private var switchedFromEmail = false
    private var handledChallenge = false

    init(mailbox: any EmailCodeReceiving, email: String, in session: BrowserSession) {
        self.mailbox = mailbox
        self.email = email
        generation = session.cancellationGeneration
    }

    private func checkCancellation(in session: BrowserSession) throws {
        try Task.checkCancellation()
        guard session.cancellationGeneration == generation else { throw CancellationError() }
    }

    // Caller has identified a login action that could cause OpenAI to send mail.
    // A mailbox error leaves that action available and the resulting challenge manual.
    static func performTrigger<Result>(
        request: ExternalLoginMailRequest?, in session: BrowserSession, from pageURL: URL?,
        skipped: Result, wasSubmitted: (Result) -> Bool, submit: () async throws -> Result
    ) async throws -> Result {
        guard let request else { return try await submit() }
        guard let pageURL, try await request.prepare(in: session, pageURL: pageURL) else { return skipped }
        let startedAt = Date()
        let result = try await submit()
        try request.checkCancellation(in: session)
        if wasSubmitted(result) { request.recordTrigger(startedAt: startedAt) }
        return result
    }

    private func prepare(in session: BrowserSession, pageURL: URL) async throws -> Bool {
        try checkCancellation(in: session)
        guard TrustedChatGPTOrigin.allowsAuthentication(pageURL), session.webView.url == pageURL,
              !session.webView.isLoading else { return false }
        if !preparedRecently(for: pageURL) {
            let baseline = try? await mailbox.captureBaseline()
            try checkCancellation(in: session)
            guard session.webView.url == pageURL, !session.webView.isLoading else { return false }
            prepared = (pageURL, baseline, .now)
        }
        let currentURL = try await session.evaluate("location.href") as? String
        try checkCancellation(in: session)
        return currentURL == pageURL.absoluteString && session.webView.url == pageURL && !session.webView.isLoading
    }

    private func preparedRecently(for pageURL: URL) -> Bool {
        guard let prepared, prepared.pageURL == pageURL else { return false }
        return ContinuousClock.now < prepared.capturedAt.advanced(by: .seconds(5))
    }

    private func recordTrigger(startedAt: Date) {
        let baseline = prepared?.baseline
        prepared = nil
        defer { switchedFromEmail = false }
        // This provider has no message timestamp. An earlier request that has yet
        // to deliver its code could otherwise look like the new request's code.
        if let baseline, !baseline.isEmpty,
           !switchedFromEmail || (request != nil && baseline != request?.baseline && ExternalMailboxCodeClient.baselineHasCode(baseline)) {
            request = Request(baseline: baseline, startedAt: startedAt)
        } else {
            request = nil
        }
        handledChallenge = false
    }

    func switchedToPassword() {
        switchedFromEmail = true
    }

    func submit(in session: BrowserSession, state: RegistrationForm.State) async throws -> Bool {
        try checkCancellation(in: session)
        guard !handledChallenge else { throw ExternalLoginMailError.submissionUnconfirmed }
        guard let request else { throw ExternalLoginMailError.baselineUnavailable }
        guard state.displayedEmail?.caseInsensitiveCompare(email) == .orderedSame else {
            throw ExternalLoginMailError.wrongRecipient
        }
        guard state.kind == .emailCode, let pageURL = state.pageURL, pageURL == session.webView.url,
              ChatGPTAutomation.isPasswordEmailCodeRoute(pageURL) else { return false }
        let token = UUID().uuidString
        guard try await RegistrationForm.externalEmailCodeScreenMatches(
            in: session, expectedEmail: email, pageURL: pageURL, token: token, capture: true
        ) else { throw ExternalLoginMailError.challengeChanged }
        try checkCancellation(in: session)
        handledChallenge = true
        let previousMessage = session.operationMessage
        defer { session.setOperationMessage(previousMessage) }
        session.setOperationMessage("Ожидается свежий код OpenAI из внешней почты…")

        let isCurrent: @MainActor @Sendable () async throws -> Bool = {
            try self.checkCancellation(in: session)
            guard session.webView.url == pageURL, !session.webView.isLoading else { return false }
            do {
                return try await RegistrationForm.externalEmailCodeScreenMatches(
                    in: session, expectedEmail: self.email, pageURL: pageURL, token: token)
            } catch {
                try self.checkCancellation(in: session)
                return false
            }
        }
        guard try await isCurrent() else { return false }
        let code: MailVerificationCode?
        do {
            code = try await withThrowingTaskGroup(of: MailVerificationCode?.self) { group in
                defer { group.cancelAll(); mailbox.cancel() }
                group.addTask { @MainActor @Sendable in
                    try await self.mailbox.waitForCode(alias: self.email, since: request.startedAt,
                                                       excluding: request.baseline, purpose: .login)
                }
                group.addTask { @MainActor @Sendable in
                    while try await isCurrent() { try await Task.sleep(for: .milliseconds(350)) }
                    return nil
                }
                return try await group.next() ?? nil
            }
        } catch {
            try checkCancellation(in: session)
            guard try await isCurrent() else { return false }
            throw ExternalLoginMailError.mailboxUnavailable
        }
        try checkCancellation(in: session)
        guard let code, try await isCurrent() else { return false }
        guard !request.baseline.contains(code.messageID) else { throw ExternalLoginMailError.mailboxUnavailable }
        do {
            if try await RegistrationForm.submitEmailCode(code.code, expectedEmail: email,
                                                          observedScreenToken: token, in: session) {
                return true
            }
        } catch {
            try checkCancellation(in: session)
        }
        // An unconfirmed click could have sent the code before the browser changed.
        guard try await isCurrent() else { return false }
        throw ExternalLoginMailError.submissionUnconfirmed
    }
}
