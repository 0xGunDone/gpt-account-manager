import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class SettingsWebView: WKWebView {
    var waitingForInbox = false
    var stoppedLoads = 0
    override var isLoading: Bool { waitingForInbox }
    override func stopLoading() { stoppedLoads += 1 }
}

@MainActor
@Suite(.serialized)
struct MailRuMailboxSettingsTests {
    private func mailbox(defaults: UserDefaults, expectedMailbox: String? = nil) -> (MailRuMailbox, SettingsWebView) {
        _ = NSApplication.shared
        var view: SettingsWebView!
        let mailbox = MailRuMailbox(expectedMailbox: expectedMailbox, defaults: defaults) { configuration in
            configuration.websiteDataStore = .nonPersistent()
            view = SettingsWebView(frame: .zero, configuration: configuration)
            return view
        }
        return (mailbox, view)
    }

    @Test func freshInstallHasNoPersonalMailbox() async throws {
        let name = "MailRuMailboxSettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let (mailbox, _) = mailbox(defaults: defaults)
        #expect(mailbox.expectedMailbox.isEmpty)
        #expect(defaults.string(forKey: MailRuMailbox.expectedMailboxKey) == nil)
        await #expect(throws: (any Error).self) { try await mailbox.captureBaseline() }
        #expect(mailbox.status.contains("Укажите и сохраните"))
    }

    @Test func mailboxPersistsNormalizedAddressAndRejectsInvalidInput() throws {
        let name = "MailRuMailboxSettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let (first, _) = mailbox(defaults: defaults)
        try first.setExpectedMailbox(" Friend@Mail.Ru \n")
        #expect(first.expectedMailbox == "friend@mail.ru")
        #expect(defaults.string(forKey: MailRuMailbox.expectedMailboxKey) == "friend@mail.ru")
        let (second, _) = mailbox(defaults: defaults)
        #expect(second.expectedMailbox == "friend@mail.ru")
        #expect(throws: MailVerificationError.invalidAlias) { try second.setExpectedMailbox("friend @mail.ru") }
        #expect(second.expectedMailbox == "friend@mail.ru")
        #expect(defaults.string(forKey: MailRuMailbox.expectedMailboxKey) == "friend@mail.ru")
        try second.setExpectedMailbox(" \n")
        #expect(mailbox(defaults: defaults).0.expectedMailbox.isEmpty)
    }

    @Test func explicitFixtureDoesNotReadOrWritePreferences() throws {
        let name = "MailRuMailboxSettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("saved@mail.ru", forKey: MailRuMailbox.expectedMailboxKey)
        let (fixture, _) = mailbox(defaults: defaults, expectedMailbox: "owner@mail.ru")
        #expect(fixture.expectedMailbox == "owner@mail.ru")
        try fixture.setExpectedMailbox("other@mail.ru")
        #expect(defaults.string(forKey: MailRuMailbox.expectedMailboxKey) == "saved@mail.ru")
    }

    @Test func changingMailboxClearsReadingResultAndCancelsOldPolling() async throws {
        let name = "MailRuMailboxSettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let (mailbox, view) = mailbox(defaults: defaults)
        try mailbox.setExpectedMailbox("owner@mail.ru")
        await mailbox.checkReading()
        #expect(mailbox.lastReadingCheck != nil)
        try mailbox.setExpectedMailbox("friend@mail.ru")
        #expect(mailbox.lastReadingCheck == nil)
        #expect(mailbox.status.contains("friend@mail.ru"))
        view.waitingForInbox = true
        let pending = Task { try await mailbox.captureBaseline() }
        await Task.yield()
        try mailbox.setExpectedMailbox("next@mail.ru")
        await #expect(throws: MailVerificationError.cancelled) { try await pending.value }
        #expect(view.stoppedLoads == 1)
        #expect(mailbox.lastReadingCheck == nil)
        #expect(mailbox.status.contains("next@mail.ru"))
    }
}
