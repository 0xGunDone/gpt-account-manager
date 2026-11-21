import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct MailRuDOMTests {
    private func fixture(_ html: String, url: String) async throws -> WKWebView {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<60 where webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        return webView
    }

    private func read<Value: Decodable>(_ script: String, from webView: WKWebView) async throws -> Value {
        let json: String = try await withCheckedThrowingContinuation { continuation in
            webView.__callAsyncJavaScript("return await (" + script + ");", arguments: [:], inFrame: nil, in: .page) { value, error in
                if let error { continuation.resume(throwing: error); return }
                guard let json = value as? String else {
                    continuation.resume(throwing: MailVerificationError.unsupportedLayout); return
                }
                continuation.resume(returning: json)
            }
        }
        return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private var inboxHTML: String {
        """
        <html><head><title>Входящие - owner@mail.ru - Почта Mail.ru</title></head><body>
        <span>owner@mail.ru</span><a href="https://auth.mail.ru/cgi-bin/logout">Выйти</a>
        <table><tbody>
        <tr class="messageline" id="msglist-1001">
          <td class="messageline__from"><a class="messageline__link" href="/message/1001/?folder=0">ChatGPT</a></td>
          <td class="messageline__subject"><a class="messageline__link" title="Ваш код ChatGPT 123456" href="/message/1001/?folder=0">Ваш код ChatGPT 123456</a></td>
          <td class="messageline__date" title="Среда, 7 октября 2026, 01:20 +03:00"><span>1:20</span></td>
        </tr>
        <tr class="messageline" id="msglist-1002">
          <td class="messageline__from"><a class="messageline__link" href="/message/1002/?folder=0">Delivery</a></td>
          <td class="messageline__subject"><a class="messageline__link" href="/message/1002/?folder=0">Unrelated message</a></td>
          <td class="messageline__date" title="Вторник, 6 октября 2026, 18:30 +03:00"><span>Вчера</span></td>
        </tr>
        <tr class="messageline" id="msglist-1003" hidden>
          <td><a class="messageline__link" href="/message/1003/?folder=0">Hidden</a></td>
        </tr>
        <tr class="messageline" id="msglist-1004">
          <td><a class="messageline__link" href="https://attacker.example/message/1004/?folder=0">External</a></td>
        </tr>
        </tbody></table></body></html>
        """
    }

    @Test(arguments: ["https://e.mail.ru/inbox/", "https://e.mail.ru/messages/inbox?12345678",
                      "https://e.mail.ru/messages/inbox?page=1&sortby=A"])
    func lightInboxUsesRenderedRowsAtBothObservedRoutes(url: String) async throws {
        let webView = try await fixture(inboxHTML, url: url)
        let snapshot: MailboxInboxSnapshot = try await read(MailRuMailbox.inboxScript, from: webView)
        #expect(snapshot.supported)
        #expect(snapshot.mailbox == "owner@mail.ru")
        #expect(Set(snapshot.entries.map(\.id)) == ["1001", "1002"])
        let verification = try #require(snapshot.entries.first(where: { $0.id == "1001" }))
        #expect(verification.url.absoluteString == "https://e.mail.ru/message/1001/?folder=0")
        #expect(verification.subject == "Ваш код ChatGPT 123456")
        #expect(verification.receivedAt == "Среда, 7 октября 2026, 01:20 +03:00")
    }

    @Test func mailboxIdentityAndActiveLoginMustBeUnambiguous() async throws {
        for html in [
            inboxHTML.replacingOccurrences(of: "<span>owner@mail.ru</span>", with: "<span>other@mail.ru</span>"),
            inboxHTML.replacingOccurrences(of: "</body>", with: "<input type='password'></body>"),
            inboxHTML.replacingOccurrences(of: "https://auth.mail.ru/cgi-bin/logout", with: "https://attacker.example/cgi-bin/logout"),
        ] {
            let webView = try await fixture(html, url: "https://e.mail.ru/inbox/")
            let snapshot: MailboxInboxSnapshot = try await read(MailRuMailbox.inboxScript, from: webView)
            #expect(!snapshot.supported)
        }
    }

    @Test(arguments: ["(1) ", "(12) ", "(999) "])
    func unreadMailCounterDoesNotHideIncomingVerificationMessage(prefix: String) async throws {
        let html = inboxHTML.replacingOccurrences(of: "<title>Входящие", with: "<title>\(prefix)Входящие")
        let webView = try await fixture(html, url: "https://e.mail.ru/inbox/")
        let snapshot: MailboxInboxSnapshot = try await read(MailRuMailbox.inboxScript, from: webView)
        #expect(snapshot.supported)
        #expect(snapshot.mailbox == "owner@mail.ru")
        #expect(snapshot.entries.contains { $0.id == "1001" && $0.subject == "Ваш код ChatGPT 123456" })
    }

    private func messageHTML(spoofHeadersInBody: Bool = false, downloadInBody: Bool = false) -> String {
        let headers = """
        <table><tbody>
          <tr id="msgFieldFrom"><td><span class="val">ChatGPT &lt;noreply_at_tm_openai_com_fixture_123abc@icloud.com&gt;</span></td></tr>
          <tr id="msgFieldTo"><td><span class="val">Hide My Email &lt;alias@icloud.com&gt;</span></td></tr>
        </tbody></table>
        """
        let download = "<a href='/cgi-bin/getmsg?id=1001'>Скачать</a>"
        return """
        <html><body>
        \(spoofHeadersInBody ? "" : headers)
        \(downloadInBody ? "" : download)
        <div id="ReadMsgBody"><div id="MSG1001"><div id="MSGINNER1001"><div id="1001_TEXT">
          <div id="viewmessagebody" class="mr_read__body"><div id="viewmessagebody_BODY" class="mr_read__body__content">
            \(spoofHeadersInBody ? headers : "")\(downloadInBody ? download : "")
            <p>Введите этот временный код подтверждения, чтобы изменить адрес электронной почты в вашей учетной записи ChatGPT:</p>
            <p>123456</p>
          </div></div>
        </div></div></div></div>
        <p>Unrelated reply preview with code 654321</p>
        <script>
          window.fetch = async (url, options) => {
            document.body.dataset.fetchURL = url;
            document.body.dataset.fetchRedirect = options.redirect;
            const payload = 'From: fixture@example.com\\r\\nTo: alias@icloud.com\\r\\nX-Fixture: header-only\\r\\n\\r\\nPRIVATE MIME BODY';
            return { ok: true, url, body: new ReadableStream({start(controller) {
              controller.enqueue(new TextEncoder().encode(payload)); controller.close();
            }}) };
          };
        </script>
        </body></html>
        """
    }

    @Test func lightMessageScopesHeadersBodyAndObservedDownloadURL() async throws {
        let webView = try await fixture(messageHTML(), url: "https://e.mail.ru/message/1001/?folder=0")
        let snapshot: MailboxMessageSnapshot = try await read(MailRuMailbox.messageScript, from: webView)
        #expect(snapshot.supported)
        #expect(snapshot.sender == "ChatGPT <noreply_at_tm_openai_com_fixture_123abc@icloud.com>")
        #expect(snapshot.recipient == "Hide My Email <alias@icloud.com>")
        #expect(snapshot.body.contains("123456"))
        #expect(!snapshot.body.contains("654321"))
        #expect(snapshot.rawHeaders?.contains("X-Fixture: header-only") == true)
        #expect(snapshot.rawHeaders?.contains("PRIVATE MIME BODY") == false)
        let observed: [String: String] = try await read("JSON.stringify({url:document.body.dataset.fetchURL, redirect:document.body.dataset.fetchRedirect})", from: webView)
        #expect(observed["url"] == "https://e.mail.ru/cgi-bin/getmsg?id=1001")
        #expect(observed["redirect"] == "error")
    }

    @Test func bodyCannotImpersonateMailboxHeadersOrDownloadControl() async throws {
        for html in [messageHTML(spoofHeadersInBody: true), messageHTML(downloadInBody: true)] {
            let webView = try await fixture(html, url: "https://e.mail.ru/message/1001/?folder=0")
            let snapshot: MailboxMessageSnapshot = try await read(MailRuMailbox.messageScript, from: webView)
            #expect(!snapshot.supported)
            #expect(snapshot.rawHeaders == "")
        }
    }
}
