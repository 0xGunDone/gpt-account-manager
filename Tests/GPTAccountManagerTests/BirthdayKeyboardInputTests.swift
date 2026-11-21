import AppKit
import SwiftUI
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct BirthdayKeyboardInputTests {
    private let profileURL = URL(string: "https://auth.openai.com/about-you")!

    private func fixture(extra: String = "", script: String = "", url: URL? = nil) async throws -> (BrowserSession, NSWindow) {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString("""
        <form onsubmit="event.preventDefault();window.submissions=(window.submissions||0)+1">
          <label>Full name <input name="name" value="Alex Green"></label>
          <div role="group" aria-label="Birthday">
            <div role="spinbutton" contenteditable="true" tabindex="0" data-type="day" aria-label="Day">DD</div>
            <div role="spinbutton" contenteditable="true" tabindex="0" data-type="month" aria-label="Month">MM</div>
            <div role="spinbutton" contenteditable="true" tabindex="0" data-type="year" aria-label="Year">YYYY</div>
            <input type="hidden" name="birthday">
          </div>
          \(extra)<button>Continue</button>
        </form>
        <script>
          window.trustedKeys = 0;
          const segments = [...document.querySelectorAll('[role=spinbutton]')];
          function commit() {
            const parts = Object.fromEntries(segments.map(e => [e.dataset.type, e.getAttribute('aria-valuenow')]));
            if (parts.year && parts.month && parts.day)
              document.querySelector('[name=birthday]').value = parts.year + '-' + parts.month.padStart(2,'0') + '-' + parts.day.padStart(2,'0');
          }
          for (const segment of segments) {
            segment.addEventListener('keydown', event => {
              if (!event.isTrusted) return;
              window.trustedKeys++;
              if (event.key === 'Backspace') {
                event.preventDefault(); segment.dataset.typed = ''; segment.textContent = ''; segment.removeAttribute('aria-valuenow'); return;
              }
              if (!/^[0-9]$/.test(event.key)) return;
              event.preventDefault();
              segment.dataset.typed = (segment.dataset.typed || '') + event.key;
              segment.textContent = String(Number(segment.dataset.typed));
              segment.setAttribute('aria-valuenow', segment.textContent);
              if (segment.dataset.typed.length === (segment.dataset.type === 'year' ? 4 : 2))
                segments[segments.indexOf(segment) + 1]?.focus();
              commit();
            });
            segment.addEventListener('blur', commit);
          }
          \(script)
        </script>
        """, baseURL: url ?? profileURL)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        try #require(!session.webView.isLoading)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: BrowserView(session: session))
        session.setVisible(true)
        window.contentView?.layoutSubtreeIfNeeded()
        try #require(await session.waitUntilAttached(seconds: 2))
        return (session, window)
    }

    @Test func nativeKeysCommitBirthdayWhenSyntheticKeysAreIgnoredWithoutSubmitting() async throws {
        let (session, window) = try await fixture()
        defer { session.cancelLoading(); window.contentView = nil }
        _ = try await session.evaluate("""
        (() => { for (const e of document.querySelectorAll('[role=spinbutton]'))
          for (const key of '1998') e.dispatchEvent(new KeyboardEvent('keydown', {key, bubbles:true})); return true; })()
        """)
        #expect(try await session.evaluate("document.querySelector('[name=birthday]').value") as? String == "")
        #expect(await session.fillBirthdayUsingKeyboard("1998-02-03", expectedURL: profileURL, expectedName: "Alex Green"))
        #expect(try await session.evaluate("document.querySelector('[name=birthday]').value") as? String == "1998-02-03")
        #expect(try await session.evaluate("window.trustedKeys") as? Int == 11)
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test func profileFillingFallsBackToNativeBirthdayKeysWithoutSubmitting() async throws {
        let (session, window) = try await fixture()
        defer { session.cancelLoading(); window.contentView = nil }
        #expect(try await RegistrationForm.fillProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
        #expect(try await session.evaluate("document.querySelector('[name=birthday]').value") as? String == "1998-02-03")
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test(arguments: ["1998-02-30", "1998-2-03", "2027-01-01"])
    func invalidDatesNeverType(date: String) async throws {
        let (session, window) = try await fixture()
        defer { session.cancelLoading(); window.contentView = nil }
        #expect(await !session.fillBirthdayUsingKeyboard(date, expectedURL: profileURL, expectedName: "Alex Green"))
        #expect(try await session.evaluate("window.trustedKeys") as? Int == 0)
    }

    @Test func wrongRouteNameAndExtraEditableFieldNeverType() async throws {
        for (extra, url, name) in [
            ("", URL(string: "https://auth.openai.com/log-in")!, "Alex Green"),
            ("", profileURL, "Other Name"),
            ("<input name='password'>", profileURL, "Alex Green"),
            ("<div contenteditable='true'>Extra</div>", profileURL, "Alex Green"),
        ] {
            let (session, window) = try await fixture(extra: extra, url: url)
            #expect(await !session.fillBirthdayUsingKeyboard("1998-02-03", expectedURL: url, expectedName: name))
            #expect(try await session.evaluate("window.trustedKeys") as? Int == 0)
            session.cancelLoading(); window.contentView = nil
        }
    }

    @Test func routeChangeOnFirstKeyStopsRemainingInput() async throws {
        let (session, window) = try await fixture(script: "segments[2].addEventListener('keydown', () => history.replaceState(null,'','/log-in')); ")
        defer { session.cancelLoading(); window.contentView = nil }
        #expect(await !session.fillBirthdayUsingKeyboard("1998-02-03", expectedURL: profileURL, expectedName: "Alex Green"))
        #expect(try await session.evaluate("window.trustedKeys") as? Int == 1)
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test func replacingDocumentAtSameURLStopsRemainingInput() async throws {
        let (session, window) = try await fixture(script: """
        segments[2].addEventListener('keydown', () => {
          const replacement = '<body>' + document.querySelector('form').outerHTML + '</body>';
          document.open(); document.write(replacement); document.close();
          document.querySelector('[data-type=year]').focus();
          window.replacementKeys = 0;
          document.addEventListener('keydown', event => { if (document.contains(event.target)) window.replacementKeys++; });
        }, {once:true});
        """)
        defer { session.cancelLoading(); window.contentView = nil }
        #expect(await !session.fillBirthdayUsingKeyboard("1998-02-03", expectedURL: profileURL, expectedName: "Alex Green"))
        #expect(session.webView.url == profileURL)
        #expect(try await session.evaluate("document.querySelector('[data-type=year]').getAttribute('aria-valuenow') === null") as? Bool == true)
        #expect(try await session.evaluate("document.querySelector('[name=birthday]').value") as? String == "")
        #expect(try await session.evaluate("window.replacementKeys") as? Int == 0)
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test func cancellationWhileWaitingForAttachmentNeverTypes() async throws {
        let (session, window) = try await fixture()
        defer { session.cancelLoading(); window.contentView = nil }
        window.contentView = nil
        let task = Task { await session.fillBirthdayUsingKeyboard("1998-02-03", expectedURL: profileURL, expectedName: "Alex Green") }
        try await Task.sleep(for: .milliseconds(40))
        session.cancelLoading()
        task.cancel()
        #expect(await !task.value)
        #expect(try await session.evaluate("window.trustedKeys") as? Int == 0)
    }

    @Test func cancellationDuringNativeInputStopsRemainingKeys() async throws {
        let (session, window) = try await fixture()
        defer { session.cancelLoading(); window.contentView = nil }
        let task = Task { await session.fillBirthdayUsingKeyboard("1998-02-03", expectedURL: profileURL, expectedName: "Alex Green") }
        for _ in 0..<100 {
            let observed = try? await session.evaluate("window.trustedKeys")
            if let keys = observed as? Int, keys > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        session.cancelLoading()
        #expect(await !task.value)
        let keys = try await session.evaluate("window.trustedKeys") as? Int ?? 0
        #expect(keys > 0 && keys < 11)
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }
}
