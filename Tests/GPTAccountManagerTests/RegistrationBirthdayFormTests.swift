import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct RegistrationBirthdayFormTests {
    private func fixture(_ html: String, url: String = "https://auth.openai.com/about-you") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 390, height: 844)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<60 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        return session
    }

    private func segmented(order: [String] = ["day", "month", "year"], extra: String = "") -> String {
        let labels = ["day": "день", "month": "месяц", "year": "год"]
        let segments = order.map { part in
            "<div role='spinbutton' contenteditable='true' tabindex='0' data-type='\(part)' aria-label='\(labels[part]!)' aria-valuemin='1' aria-valuemax='\(part == "year" ? 2100 : part == "month" ? 12 : 31)'>\(part)</div>"
        }.joined()
        return """
        <h1>Давайте подтвердим ваш возраст</h1>
        <form onsubmit="event.preventDefault();window.submissions=(window.submissions||0)+1;window.sentBirthday=document.querySelector('[name=birthday]').value">
          <label>Полное имя <input name='name'></label>
          <div role='group' aria-label='День рождения'>\(segments)<input type='hidden' name='birthday'></div>
          \(extra)<button>Продолжить</button>
        </form>
        <script>
          for (const segment of document.querySelectorAll('[role=spinbutton]')) {
            segment.addEventListener('focus', () => segment.dataset.typed='');
            segment.addEventListener('keydown', event => {
              if (!/^[0-9]$/.test(event.key)) return;
              event.preventDefault();
              segment.dataset.typed += event.key;
              segment.textContent=String(Number(segment.dataset.typed));
              segment.setAttribute('aria-valuenow', segment.textContent);
            });
            segment.addEventListener('blur', () => {
              const parts={};
              for (const item of document.querySelectorAll('[role=spinbutton]')) parts[item.dataset.type]=item.getAttribute('aria-valuenow');
              if (parts.year && parts.month && parts.day) document.querySelector('[name=birthday]').value=parts.year+'-'+parts.month.padStart(2,'0')+'-'+parts.day.padStart(2,'0');
            });
          }
        </script>
        """
    }

    @Test func recognizesVisibleBirthdaySegmentsWithoutGuessingAge() async throws {
        let session = try await fixture(segmented())
        #expect(try await RegistrationForm.inspect(in: session).kind == .profile)
        #expect(try await RegistrationForm.inspect(in: session).profileRequiresBirthDate)
        #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, in: session))
        #expect(try await session.evaluate("document.querySelector('[name=name]').value") as? String == "")
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test(arguments: [["day", "month", "year"], ["month", "day", "year"], ["year", "month", "day"]])
    func submitsCommittedBirthdayUsingSemanticSegmentOrder(order: [String]) async throws {
        let session = try await fixture(segmented(order: order))
        #expect(try await RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
        #expect(try await session.evaluate("window.sentBirthday") as? String == "1998-02-03")
        #expect(try await session.evaluate("window.submissions") as? Int == 1)
    }

    @Test(arguments: ["1998-02-30", "1998-2-03", "1998-02-03T00:00:00Z", "", "2027-01-01"])
    func invalidBirthdayNeverTouchesFields(birthday: String) async throws {
        let session = try await fixture(segmented())
        #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: birthday, in: session))
        #expect(try await session.evaluate("document.querySelector('[name=name]').value") as? String == "")
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test func missingAmbiguousOrUnownedBirthdayControlsRemainUntouched() async throws {
        let base = segmented()
        let invalid = [
            base.replacingOccurrences(of: "data-type='day'", with: "data-type='other'").replacingOccurrences(of: "aria-label='день'", with: "aria-label='other'"),
            segmented(extra: "<input aria-label='Extra'>"),
            segmented(extra: "<div contenteditable='true'>Other editable</div>"),
            base.replacingOccurrences(of: "<button>", with: "<button>Continue</button><button>"),
            base.replacingOccurrences(of: "<form ", with: "<form action='https://other.example/' "),
            base.replacingOccurrences(of: "aria-label='День рождения'", with: "aria-label='Other date'"),
        ]
        for html in invalid {
            let session = try await fixture(html)
            #expect(try await RegistrationForm.inspect(in: session).kind == .unknown)
            #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
            #expect(try await session.evaluate("document.querySelector('[name=name]').value") as? String == "")
        }
    }

    @Test func spinnerDisplayWithoutCommittedApplicationValueNeverSubmits() async throws {
        let session = try await fixture(segmented().replacingOccurrences(of: "if (parts.year && parts.month && parts.day)", with: "if (false)"))
        #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test(arguments: ["form='other'", "disabled"])
    func hiddenBirthdayMustBelongToEnabledSubmittedForm(attribute: String) async throws {
        let html = segmented().replacingOccurrences(of: "type='hidden' name='birthday'", with: "type='hidden' name='birthday' \(attribute)") + "<form id='other'></form>"
        let session = try await fixture(html)
        #expect(try await RegistrationForm.inspect(in: session).kind == .unknown)
        #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
        #expect(try await session.evaluate("document.querySelector('[name=name]').value") as? String == "")
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test func waitsForDelayedContinueAfterBirthdayCommit() async throws {
        let html = segmented().replacingOccurrences(of: "<button>", with: "<button disabled>") + """
        <script>document.querySelector('[data-type=day]').addEventListener('blur',()=>setTimeout(()=>document.querySelector('button').disabled=false,150));</script>
        """
        let session = try await fixture(html)
        #expect(try await RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
        #expect(try await session.evaluate("window.submissions") as? Int == 1)
    }

    @Test func supportsNativeDateAndScopedInputSelectParts() async throws {
        let forms = [
            "<label>Date of birth <input type='date' name='birthday' required></label>",
            "<div role='group' aria-label='Birthday'><input type='date' required></div>",
            "<fieldset><legend>Date of birth</legend><label>Month <select name='month'><option value='02'>February</option></select></label><label>Day <input name='day' type='number'></label><label>Year <input name='year' type='number'></label></fieldset>",
        ]
        for fields in forms {
            let session = try await fixture("<form onsubmit=\"event.preventDefault();window.submissions=1\"><label>Full name <input name='name'></label>\(fields)<button>Continue</button></form>")
            #expect(try await RegistrationForm.inspect(in: session).profileRequiresBirthDate)
            #expect(try await RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
            #expect(try await session.evaluate("window.submissions") as? Int == 1)
        }
    }

    @Test func fillOnlyCommitsBirthdayWithoutClickingContinue() async throws {
        let session = try await fixture(segmented())
        #expect(try await RegistrationForm.fillProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
        #expect(try await session.evaluate("document.querySelector('[name=birthday]').value") as? String == "1998-02-03")
        #expect(try await session.evaluate("document.querySelector('[name=name]').value") as? String == "Alex Green")
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test func routeChangeDuringSegmentEventsStopsBeforeContinue() async throws {
        let session = try await fixture(segmented() + """
        <script>document.querySelector('[data-type=year]').addEventListener('keydown',()=>history.replaceState(null,'','/log-in'));</script>
        """)
        #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
        #expect(try await session.evaluate("window.submissions === undefined") as? Bool == true)
    }

    @Test func wrongRouteCannotReceiveBirthday() async throws {
        let session = try await fixture(segmented(), url: "https://auth.openai.com/log-in")
        #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: session))
        let untrusted = try await fixture(segmented(), url: "https://other.example/about-you")
        await #expect(throws: BrowserSessionError.untrustedOrigin) {
            try await RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, birthDate: "1998-02-03", in: untrusted)
        }
    }
}
