import Foundation
import Testing
@testable import GPTAccountManager

struct MailVerificationTests {
    private let since = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(
        id: String = "new-message", sender: String = "OpenAI <noreply@tm.openai.com>",
        recipient: String = "alias@icloud.com", originalSender: String? = nil,
        offset: TimeInterval = 1, subject: String = "Confirm your new email address",
        body: String = "Use verification code 123456 to change your email."
    ) -> MailVerificationMessage {
        .init(messageID: id, sender: sender, recipient: recipient, originalSender: originalSender,
              receivedAt: since.addingTimeInterval(offset), subject: subject, body: body)
    }

    private func match(_ messages: [MailVerificationMessage], excluding: Set<String> = []) throws -> MailVerificationCode? {
        try MailVerificationMatcher.match(messages: messages, alias: "alias@icloud.com",
                                          since: since, excluding: excluding,
                                          now: since.addingTimeInterval(60))
    }

    @Test func exactFreshRecipientAndOpenAISenderProduceCode() throws {
        #expect(try match([message(recipient: "Alias <ALIAS@iCloud.com>")]) ==
                .init(messageID: "new-message", code: "123456"))
    }

    @Test func preexistingOldAndFutureMessagesCannotSupplyCode() throws {
        #expect(try match([message(id: "existing")], excluding: ["existing"]) == nil)
        #expect(try match([message(offset: -1)]) == nil)
        #expect(try match([message(offset: 61)]) == nil)
    }

    @Test func aliasesMatchExactlyWithoutPlusOrDotNormalization() throws {
        #expect(try match([message(recipient: "alias+other@icloud.com")]) == nil)
        #expect(try match([message(recipient: "a.lias@icloud.com")]) == nil)
        #expect(try match([message(recipient: "other@icloud.com")]) == nil)
        #expect(try match([message(recipient: "alias@icloud.com, other@icloud.com")]) == nil)
        #expect(MailVerificationMatcher.normalizedAddress(" ALIAS@iCloud.com\n") == "alias@icloud.com")
        #expect(MailVerificationMatcher.normalizedAddress("alias @icloud.com") == nil)
    }

    @Test func senderDomainBoundaryRejectsLookalikesAndBodySpoofing() throws {
        #expect(try match([message(sender: "noreply@openai.com.attacker.test")]) == nil)
        #expect(try match([message(sender: "noreply@notopenai.com")]) == nil)
        #expect(try match([message(sender: "attacker@example.com",
                                  body: "From: noreply@openai.com\nConfirm new email address with code 123456")]) == nil)
        #expect(try match([message(sender: "noreply@openai.com, attacker@example.com")]) == nil)
        #expect(try match([message(sender: "noreply@openai.com <attacker>")]) == nil)
        #expect(try match([message(sender: "noreply@openai.com <attacker@example.com>")]) == nil)
    }

    @Test func iCloudForwardingRequiresOriginalSenderInMailboxHeaders() throws {
        #expect(try match([message(sender: "forwarder@icloud.com", originalSender: "noreply@openai.com")]) != nil)
        #expect(try match([message(sender: "forwarder@icloud.com")]) == nil)
        #expect(try match([message(sender: "forwarder@icloud.com", originalSender: "noreply@example.com")]) == nil)
        #expect(try match([message(sender: "forwarder@icloud.com.attacker.test", originalSender: "noreply@openai.com")]) == nil)
    }

    @Test func loginAndPasswordResetCodesAreNotEmailChangeCodes() throws {
        #expect(try match([message(subject: "Your login code", body: "Your verification code is 123456.")]) == nil)
        #expect(try match([message(subject: "Reset your password", body: "Your verification code is 123456.")]) == nil)
    }

    @Test func registrationAndLoginPurposeKeepIdentityFreshnessAndMessageSeparation() throws {
        func purposeMatch(_ message: MailVerificationMessage, _ purpose: MailVerificationPurpose,
                          excluding: Set<String> = []) throws -> MailVerificationCode? {
            try MailVerificationMatcher.match(messages: [message], alias: "alias@icloud.com", since: since,
                                              excluding: excluding, now: since.addingTimeInterval(60), purpose: purpose)
        }
        let signupEnglish = message(subject: "ChatGPT: Verify your email", body: "Your verification code is 123456. Create your account.")
        let signupRussian = message(subject: "Ваш код ChatGPT 123456", body: "Введите код подтверждения, чтобы завершить регистрацию: 123456.")
        let loginEnglish = message(subject: "Your ChatGPT code", body: "Use this verification code to log in: 123456.")
        let loginRussian = message(subject: "Ваш код ChatGPT 123456", body: "Введите временный код подтверждения, чтобы войти в вашу учетную запись ChatGPT: 123456.")
        for signup in [signupEnglish, signupRussian] {
            #expect(try purposeMatch(signup, .registration)?.code == "123456")
            #expect(try purposeMatch(signup, .login)?.code == "123456")
            #expect(try match([signup]) == nil)
        }
        #expect(try purposeMatch(message(subject: "Verify your email",
            body: "Your ChatGPT verification code is 123456. Create your account."), .registration)?.code == "123456")
        for login in [loginEnglish, loginRussian] {
            #expect(try purposeMatch(login, .login)?.code == "123456")
            #expect(try purposeMatch(login, .registration)?.code == "123456")
            #expect(try match([login]) == nil)
        }
        for purpose in [MailVerificationPurpose.registration, .login] {
            #expect(try purposeMatch(message(subject: "Ваш временный код подтверждения для ChatGPT",
                body: "Введите временный код подтверждения: 123456."), purpose)?.code == "123456")
            #expect(try purposeMatch(message(), purpose) == nil)
            #expect(try purposeMatch(message(subject: "ChatGPT reset your password", body: "Your verification code is 123456"), purpose) == nil)
            #expect(try purposeMatch(message(sender: "attacker@example.com", subject: "Your ChatGPT code", body: "Your verification code is 123456"), purpose) == nil)
            #expect(try purposeMatch(message(recipient: "other@icloud.com", subject: "Your ChatGPT code", body: "Your verification code is 123456"), purpose) == nil)
            #expect(try purposeMatch(message(offset: -1, subject: "Your ChatGPT code", body: "Your verification code is 123456"), purpose) == nil)
            #expect(try purposeMatch(message(subject: "Your ChatGPT code", body: "Your verification code is 123456"), purpose, excluding: ["new-message"]) == nil)
        }
    }

    @Test func multipleCodesAndMultipleMatchingMessagesFailClosed() throws {
        #expect(throws: MailVerificationError.ambiguousMessage) {
            try match([message(body: "Confirm new email address: 123456 or 654321.")])
        }
        #expect(throws: MailVerificationError.ambiguousMessage) {
            try match([message(id: "first"), message(id: "second")])
        }
        #expect(try match([message(body: "Confirm new email address: 123456. Code 123456.")])?.code == "123456")
        #expect(try match([message(body: "Confirm new email address: 1234567")]) == nil)
    }

    @Test func passwordChangeCodesStayBoundToRequestRecipientAndPurpose() throws {
        func passwordMatch(_ value: MailVerificationMessage, excluding: Set<String> = []) throws -> MailVerificationCode? {
            try MailVerificationMatcher.match(messages: [value], alias: "alias@icloud.com", since: since,
                excluding: excluding, now: since.addingTimeInterval(60), purpose: .passwordChange)
        }
        let generic = message(subject: "Your ChatGPT code", body: "Your verification code is 123456.")
        let reset = message(subject: "OpenAI password reset", body: "Your verification code is 123456.")
        let russian = message(subject: "Ваш код ChatGPT", body: "Код подтверждения для смены пароля: 123456.")
        for value in [generic, reset, russian] {
            #expect(try passwordMatch(value)?.code == "123456")
        }
        #expect(try MailVerificationMatcher.match(messages: [reset], alias: "alias@icloud.com", since: since,
            excluding: [], now: since.addingTimeInterval(60), purpose: .login) == nil)
        #expect(try passwordMatch(message()) == nil)
        #expect(try passwordMatch(message(recipient: "other@icloud.com", subject: generic.subject, body: generic.body)) == nil)
        #expect(try passwordMatch(message(sender: "attacker@example.com", subject: generic.subject, body: generic.body)) == nil)
        #expect(try passwordMatch(message(offset: -1, subject: generic.subject, body: generic.body)) == nil)
        #expect(try passwordMatch(generic, excluding: [generic.messageID]) == nil)
        #expect(try passwordMatch(message(subject: "OpenAI password reset", body: "Click the reset link.")) == nil)
    }

    @Test func temporaryChatGPTLoginCodeWithResetAdviceIsRecognized() throws {
        let actual = message(subject: "Your temporary ChatGPT login code", body: """
        ChatGPT Log-in Code
        We noticed a suspicious log-in on your account. If that was you, enter this code:
        123456
        If you were not trying to log in to ChatGPT, please reset your password.
        For more information, see the help center article on One-Time Passwords.
        """)
        for purpose in [MailVerificationPurpose.passwordChange, .login] {
            #expect(try MailVerificationMatcher.match(messages: [actual], alias: "alias@icloud.com", since: since,
                excluding: [], now: since.addingTimeInterval(60), purpose: purpose)?.code == "123456")
        }
        let reset = message(subject: "ChatGPT password reset", body: "Reset your password with your login code: 123456")
        #expect(try MailVerificationMatcher.match(messages: [reset], alias: "alias@icloud.com", since: since,
            excluding: [], now: since.addingTimeInterval(60), purpose: .login) == nil)
        #expect(try match([actual]) == nil)
    }

    @Test func malformedAliasIsRejectedBeforeMatching() {
        #expect(throws: MailVerificationError.invalidAlias) {
            try MailVerificationMatcher.match(messages: [message()], alias: "not email", since: since, excluding: [])
        }
    }

    @Test func lightMailboxRoutesAllowOnlyObservedInboxAndInboxMessages() {
        #expect(MailRuOrigin.isInbox(URL(string: "https://e.mail.ru/messages/inbox?12345678")))
        #expect(MailRuOrigin.isInbox(URL(string: "https://e.mail.ru/messages/inbox")))
        #expect(!MailRuOrigin.isInbox(URL(string: "https://e.mail.ru/messages/inbox?redirect=https://example.com")))
        #expect(MailRuOrigin.messageID(URL(string: "https://e.mail.ru/message/12345678901234567890/?folder=0")) == "12345678901234567890")
        for value in ["https://e.mail.ru/message/12345/?folder=1", "https://e.mail.ru/message/12345/?folder=0&next=example.com",
                      "https://e.mail.ru/message/12345/#evil", "https://e.mail.ru.attacker.test/message/12345/?folder=0"] {
            #expect(MailRuOrigin.messageID(URL(string: value)) == nil)
        }
    }

    @Test func lightMailboxDateParsesRussianMonthAndExplicitTimezone() throws {
        let date = try #require(MailVerificationMatcher.receivedDate(from: "Среда, 7 октября 2026, 01:20 +03:00"))
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-06T22:20:00Z"))
        #expect(MailVerificationMatcher.receivedDate(from: "Сегодня, 1:20") == nil)
        #expect(MailVerificationMatcher.receivedDate(from: "Среда, 31 февраля 2026, 01:20 +03:00") == nil)
        #expect(MailVerificationMatcher.receivedDate(from: "Среда, 7 октября 2026, 25:20 +03:00") == nil)
    }

    @Test func exactSourceSecondsRejectUnseenStaleSameMinuteAndFutureMessages() throws {
        #expect(try match([message(offset: -20)]) == nil)
        #expect(try match([message(offset: -1)]) == nil)
        #expect(try match([message(offset: 0)]) != nil)
        #expect(try match([message(offset: 61)]) == nil)
    }

    @Test func sourceDateRequiresSingleExactSecondTimestamp() throws {
        let header = "Date: Tue, 06 Oct 2026 22:20:05 +0000 (UTC)"
        #expect(MailVerificationMatcher.sourceDate(rawHeaders: header) == ISO8601DateFormatter().date(from: "2026-10-06T22:20:05Z"))
        #expect(MailVerificationMatcher.sourceDate(rawHeaders: header + "\r\n" + header) == nil)
        #expect(MailVerificationMatcher.sourceDate(rawHeaders: "Date: Tue, 06 Oct 2026 22:20 +0000") == nil)
        #expect(MailVerificationMatcher.sourceDate(rawHeaders: "Date: Tue, 31 Feb 2026 22:20:05 +0000") == nil)
        #expect(MailVerificationMatcher.sourceDate(rawHeaders: "Date: Tue, 06 Oct 2026 25:20:05 +0000") == nil)
    }

    @Test func actualRussianEmailChangePurposeMatchesButLoginDoesNot() throws {
        #expect(try match([message(subject: "Ваш код ChatGPT 123456",
            body: "Введите этот временный код подтверждения, чтобы изменить адрес электронной почты в вашей учетной записи ChatGPT: 123456")]) != nil)
        #expect(try match([message(subject: "Ваш код ChatGPT 123456",
            body: "Введите этот временный код подтверждения, чтобы войти в вашу учетную запись ChatGPT: 123456")]) == nil)
    }

    @Test func authenticatedICloudHeadersBindOriginalSenderRecipientAndForwardingMailbox() {
        let sender = "ChatGPT <noreply_at_tm_openai_com_fixture_123abc@icloud.com>"
        let recipient = "Hide My Email <alias@icloud.com>"
        let headers = """
        Authentication-Results: mxs.mail.ru; spf=pass smtp.helo=outbound.qs.icloud.com;
         dkim=pass header.d=icloud.com;
         dkim=fail reason=signature_incorrect header.d=tm.openai.com;
         dmarc=pass header.from=noreply_at_tm_openai_com_fixture_123abc@icloud.com
        DKIM-Signature: v=1; a=rsa-sha256; d=icloud.com; s=fixture;
         h=Content-Type:Date:From:Mime-Version:Message-ID:Subject:To:X-ICLOUD-HME:x-icloud-hme;
         bh=fixture; b=fixture
        DKIM-Signature: v=1; d=tm.openai.com; h=from:to:subject; b=fixture
        From: \(sender)
        To: \(recipient)
        Date: Tue, 06 Oct 2026 22:20:05 +0000 (UTC)
        X-ICLOUD-HME: p=alias@icloud.com; d=; f=owner@mail.ru; r=to; s=noreply@tm.openai.com
        """
        func verified(_ value: String, mailbox: String = "owner@mail.ru") -> String? {
            MailVerificationMatcher.verifiedOriginalSender(rawHeaders: value, visibleSender: sender,
                visibleRecipient: recipient, expectedMailbox: mailbox)
        }
        #expect(verified(headers) == "noreply@tm.openai.com")
        #expect(verified(headers, mailbox: "other@mail.ru") == nil)
        #expect(verified(headers.replacingOccurrences(of: "p=alias@icloud.com", with: "p=other@icloud.com")) == nil)
        #expect(verified(headers.replacingOccurrences(of: "s=noreply@tm.openai.com", with: "s=attacker@example.com")) == nil)
        #expect(verified(headers.replacingOccurrences(of: "dkim=pass header.d=icloud.com", with: "dkim=fail header.d=icloud.com")) == nil)
        #expect(verified(headers.replacingOccurrences(of: "X-ICLOUD-HME:x-icloud-hme", with: "Reply-To")) == nil)
        #expect(verified(headers.replacingOccurrences(of: "Content-Type:Date:From", with: "Content-Type:From")) == nil)
        #expect(verified(headers + "\nDate: Tue, 06 Oct 2026 22:20:05 +0000") == nil)
        #expect(verified(headers.replacingOccurrences(of: "mxs.mail.ru", with: "attacker.example.com")) == nil)
        #expect(verified(headers + "\nX-ICLOUD-HME: p=alias@icloud.com; f=owner@mail.ru; r=to; s=noreply@tm.openai.com") == nil)
        #expect(verified(headers + "\nAuthentication-Results: mxs.mail.ru; dkim=pass header.d=icloud.com") == nil)
        #expect(verified(headers.replacingOccurrences(of: "From: \(sender)", with: "From: attacker@icloud.com")) == nil)
    }

    @Test func mailboxOriginsNeverExtendChatGPTTrust() {
        #expect(MailRuOrigin.allowsNavigation(URL(string: "https://e.mail.ru/inbox/")))
        #expect(MailRuOrigin.allowsNavigation(URL(string: "https://id.vk.ru/auth")))
        #expect(!MailRuOrigin.allowsReading(URL(string: "https://id.vk.ru/auth")))
        #expect(!MailRuOrigin.allowsReading(URL(string: "https://mail.ru/")))
        for value in ["http://e.mail.ru/inbox/", "https://e.mail.ru.attacker.test/", "https://vk.ru/",
                      "https://example.com/", "https://user@e.mail.ru/", "https://e.mail.ru:8443/"] {
            #expect(!MailRuOrigin.allowsNavigation(URL(string: value)))
        }
        #expect(!TrustedChatGPTOrigin.allowsTopLevelNavigation(URL(string: "https://e.mail.ru/inbox/")))
    }
}
