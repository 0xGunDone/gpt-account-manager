import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct RegistrationProfileCompletionLabelTests {
    private func fixture(_ html: String, url: String = "https://auth.openai.com/about-you") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 390, height: 844)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<60 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        return session
    }

    private func profile(label: String = "Завершить создание учетной записи") -> String {
        """
        <script>window.submissions=0;</script>
        <h1>Расскажите о себе</h1>
        <form id="profile" onsubmit="event.preventDefault();window.submissions++;window.sentName=window.committedName;window.sentAge=window.committedAge">
          <label>Полное имя <input name="name" onblur="window.committedName=this.value"></label>
          <label>Возраст <input name="age" type="number" onblur="window.committedAge=this.value"></label>
          <button>\(label)</button>
        </form>
        """
    }

    @Test(arguments: [
        "Завершить создание учетной записи",
        "Завершить создание учётной записи",
        "Finish creating account",
        "Finish creating your account",
    ])
    func recognizesCompletionLabelAndSubmitsCommittedAgeOnce(label: String) async throws {
        let session = try await fixture(profile(label: label))
        let state = try await RegistrationForm.inspect(in: session)
        #expect(state.kind == .profile)
        #expect(!state.profileRequiresBirthDate)
        #expect(try await RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, in: session))
        #expect(try await session.evaluate("window.sentName") as? String == "Alex Green")
        #expect(try await session.evaluate("window.sentAge") as? String == "28")
        #expect(try await session.evaluate("window.submissions") as? Int == 1)
    }

    @Test func fillCommitsNameAndAgeWithoutSubmittingCompletionButton() async throws {
        let session = try await fixture(profile())
        #expect(try await RegistrationForm.fillProfile(fullName: "Alex Green", age: 28, in: session))
        #expect(try await session.evaluate("document.querySelector('[name=name]').value") as? String == "Alex Green")
        #expect(try await session.evaluate("document.querySelector('[name=age]').value") as? String == "28")
        #expect(try await session.evaluate("window.committedName") as? String == "Alex Green")
        #expect(try await session.evaluate("window.committedAge") as? String == "28")
        #expect(try await session.evaluate("window.submissions") as? Int == 0)
    }

    @Test(arguments: ["https://auth.openai.com/about-you/extra", "https://auth.openai.com/log-in/password", "https://chatgpt.com/about-you"])
    func completionLabelCannotIdentifyProfileOnOtherRoutes(url: String) async throws {
        try await expectUntouched(profile(), url: url)
    }

    @Test func completionLabelPreservesFormOwnershipActionAndUniquenessGuards() async throws {
        let base = profile()
        let invalid = [
            base.replacingOccurrences(of: "name=\"age\"", with: "name=\"age\" form=\"other\"") + "<form id='other'></form>",
            base.replacingOccurrences(of: "<button>", with: "<button form='other'>") + "<form id='other'></form>",
            base.replacingOccurrences(of: "id=\"profile\"", with: "id=\"profile\" action=\"https://other.example/\""),
            base.replacingOccurrences(of: "<button>", with: "<button formaction='https://other.example/'>"),
            base.replacingOccurrences(of: "</form>", with: "<button>Завершить создание учетной записи</button></form>"),
            base.replacingOccurrences(of: "</form>", with: "<label>Recovery email <input type='email' name='recovery'></label></form>"),
        ]
        for html in invalid { try await expectUntouched(html) }
    }

    @Test(arguments: ["Finish creating account now", "Завершить создание учетной записи и продолжить"])
    func completionLabelsRequireExactMatch(label: String) async throws {
        try await expectUntouched(profile(label: label))
    }

    @Test(arguments: [
        "Завершить создание учетной записи",
        "Завершить создание учётной записи",
        "Finish creating account",
        "Finish creating your account",
    ])
    func completionLabelDoesNotBecomeSharedEmailOrPasswordAction(label: String) async throws {
        for kind in ["email", "password"] {
            let session = try await fixture("""
            <script>window.submissions=0;</script>
            <form onsubmit="event.preventDefault();window.submissions++">
              <input type="\(kind)"><button>\(label)</button>
            </form>
            """, url: kind == "email" ? "https://auth.openai.com/create-account" : "https://auth.openai.com/create-account/password")
            #expect(try await RegistrationForm.inspect(in: session).kind == .unknown)
            if kind == "email" {
                #expect(try await !RegistrationForm.submitEmail("fixture@example.com", in: session))
            } else {
                #expect(try await !RegistrationForm.submitPassword("fixture-password", in: session))
            }
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
            #expect(try await session.evaluate("window.submissions") as? Int == 0)
        }
    }

    private func expectUntouched(_ html: String, url: String = "https://auth.openai.com/about-you") async throws {
        let session = try await fixture(html, url: url)
        #expect(try await RegistrationForm.inspect(in: session).kind == .unknown)
        #expect(try await !RegistrationForm.fillProfile(fullName: "Alex Green", age: 28, in: session))
        #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, in: session))
        #expect(try await session.evaluate("[...document.querySelectorAll('input')].every(input=>input.value==='')") as? Bool == true)
        #expect(try await session.evaluate("window.committedName === undefined && window.committedAge === undefined") as? Bool == true)
        #expect(try await session.evaluate("window.submissions") as? Int == 0)
    }
}
