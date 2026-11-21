import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class RecoveryMailboxWebView: WKWebView {
    var hasNewCode = false
    var inboxLoads = 0
    var messageLoads = 0

    override func load(_ request: URLRequest) -> WKNavigation? {
        let html: String
        if MailRuOrigin.isInbox(request.url) {
            inboxLoads += 1
            let rows = (hasNewCode ? ["1000", "1001"] : ["1000"]).map { id in
                "<tr class='messageline' id='msglist-\(id)'><td class='messageline__subject'><a class='messageline__link' href='/message/\(id)/?folder=0'>Ваш код ChatGPT</a></td></tr>"
            }.joined()
            html = "<title>Входящие - owner@mail.ru - Почта Mail.ru</title><span>owner@mail.ru</span><a href='https://auth.mail.ru/cgi-bin/logout'>Выйти</a><table>\(rows)</table>"
        } else {
            messageLoads += 1
            html = """
            <table><tr id='msgFieldFrom'><td><span class='val'>ChatGPT &lt;noreply_at_tm_openai_com_fixture_123abc@icloud.com&gt;</span></td></tr>
            <tr id='msgFieldTo'><td><span class='val'>Hide My Email &lt;new@icloud.com&gt;</span></td></tr></table>
            <a href='/cgi-bin/getmsg?id=1001'>Скачать</a>
            <div id='ReadMsgBody'><div id='MSG1001'><div id='viewmessagebody_BODY' class='mr_read__body__content'>Ваш код подтверждения ChatGPT: 123456.</div></div></div>
            """
        }
        return super.loadHTMLString(html, baseURL: request.url)
    }

    override func reload() -> WKNavigation? {
        load(URLRequest(url: url ?? URL(string: "https://e.mail.ru/inbox/")!))
    }
}

@MainActor
@Suite(.serialized)
struct RegistrationRecoveryTests {
    @Test(arguments: [false, true])
    func savedProfileLogsInGetsFreshMailCodeAndContinuesWithoutNewDraft(alreadyAwaitingCode: Bool) async throws {
        _ = NSApplication.shared
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        session.webView.navigationDelegate = nil
        var mailView: RecoveryMailboxWebView!
        let mailbox = MailRuMailbox(expectedMailbox: "owner@mail.ru") { configuration in
            configuration.websiteDataStore = .nonPersistent()
            let headers = """
            Authentication-Results: mxs.mail.ru; dkim=pass header.d=icloud.com
            DKIM-Signature: v=1; d=icloud.com; h=From:To:Date:X-ICLOUD-HME; b=fixture
            From: ChatGPT <noreply_at_tm_openai_com_fixture_123abc@icloud.com>
            To: Hide My Email <new@icloud.com>
            Date: fixture-date
            X-ICLOUD-HME: p=new@icloud.com; f=owner@mail.ru; r=to; s=noreply@tm.openai.com

            fixture
            """
            let json = String(decoding: try! JSONEncoder().encode(headers), as: UTF8.self)
            configuration.userContentController.addUserScript(WKUserScript(source: """
            window.fetch=async(url)=>({ok:true,url,body:new ReadableStream({start(c){
              const headers=\(json).replace(/^Date:.*$/m, 'Date: '+new Date().toUTCString().replace('GMT','+0000'));
              c.enqueue(new TextEncoder().encode(headers));c.close();
            }})});
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
            mailView = RecoveryMailboxWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            return mailView
        }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        let coordinator = RegistrationCoordinator(store: store, browser: browser, mailbox: mailbox)
        defer {
            coordinator.stop()
            session.cancelLoading()
            try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
        }
        let original = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture-password")
        var pending = try #require(original.pendingRegistration)
        pending.phase = .profile
        pending.passwordWasSubmitted = true
        pending.requestedAt = Date().addingTimeInterval(-600)
        pending.baselineMessageIDs = alreadyAwaitingCode ? ["1000"] : ["obsolete"]
        mailView.hasNewCode = alreadyAwaitingCode
        try store.checkpointRegistration(id: original.id, registration: pending)
        session.webView.loadHTMLString("""
        <script>
        window.fetch=async()=>({ok:true,json:async()=>({})});
        window.emailCount=0;window.passwordCount=0;window.codeCount=0;window.profileCount=0;
        function emailSubmit(e){e.preventDefault();window.emailCount++;window.emailSent=document.querySelector('input').value;
          history.replaceState({},'', '/log-in/password');document.body.innerHTML='<form onsubmit="passwordSubmit(event)"><p>new@icloud.com</p><input type=password><button>Continue</button></form>';}
        function passwordSubmit(e){e.preventDefault();window.passwordCount++;window.passwordSent=document.querySelector('input').value;
          history.replaceState({},'', '/email-verification');document.body.innerHTML='<main><p>Code sent to new@icloud.com</p><form onsubmit="codeSubmit(event)"><input name=code autocomplete=one-time-code><button>Continue</button></form></main>';}
        function codeSubmit(e){e.preventDefault();window.codeCount++;window.codeSent=document.querySelector('input').value;
          history.replaceState({},'', '/about-you');document.body.innerHTML='<form onsubmit="profileSubmit(event)"><input name=name><input name=age type=number><button>Continue</button></form>';}
        function profileSubmit(e){e.preventDefault();window.profileCount++;window.nameSent=document.querySelector('[name=name]').value;window.ageSent=document.querySelector('[name=age]').value;
          document.body.innerHTML='<h1>Verify you are human</h1>';}
        </script><form onsubmit='emailSubmit(event)'><input type=email><button>Continue</button></form>
        """, baseURL: URL(string: "https://auth.openai.com/log-in"))
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        if alreadyAwaitingCode {
            _ = try await session.evaluate("""
            (() => {
            history.replaceState({},'', '/email-verification');
            document.body.innerHTML='<main><p>Code sent to new@icloud.com</p><form onsubmit="codeSubmit(event)"><input name=code autocomplete=one-time-code><button>Continue</button></form></main>';
            return true;
            })()
            """)
        }
        coordinator.resume(id: original.id)
        for _ in 0..<240 {
            if (try? await session.evaluate("window.passwordCount")) as? Int == 1 { mailView.hasNewCode = true }
            if (try? await session.evaluate("window.profileCount")) as? Int == 1 || !coordinator.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let expectedLogins = alreadyAwaitingCode ? 0 : 1
        #expect(try await session.evaluate("window.emailCount") as? Int == expectedLogins)
        #expect(try await session.evaluate("window.passwordCount") as? Int == expectedLogins)
        #expect(try await session.evaluate("window.codeCount") as? Int == 1)
        #expect(try await session.evaluate("window.profileCount") as? Int == 1)
        if !alreadyAwaitingCode {
            #expect(try await session.evaluate("window.emailSent") as? String == original.email)
            #expect(try await session.evaluate("window.passwordSent") as? String == original.password)
        }
        #expect(try await session.evaluate("window.codeSent") as? String == "123456")
        #expect(try await session.evaluate("window.nameSent") as? String == pending.fullName)
        #expect(try await session.evaluate("window.ageSent") as? String == String(pending.age))
        // Completing recovery must return to enrollment, but an unrecorded factor must never publish ready.
        session.webView.loadHTMLString("""
        <button role='switch' aria-label='Authenticator app' aria-checked='true'>Authenticator app</button>
        <script>window.fetch=async()=>({ok:true,json:async()=>({user:{email:'new@icloud.com',id:'fixture-user'}})});</script>
        """, baseURL: URL(string: "https://chatgpt.com/settings/security"))
        for _ in 0..<100 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!coordinator.isRunning)
        let saved = try #require(store.accounts.first)
        #expect(store.accounts.count == 1 && store.groups.isEmpty)
        #expect(saved.id == original.id && saved.browserStoreID == original.browserStoreID)
        #expect(saved.password == original.password && saved.proxy == original.proxy)
        #expect(saved.status == .needsRecovery && saved.groupID == nil && saved.totpSecret.isEmpty)
        #expect(saved.pendingRegistration?.baselineMessageIDs == ["1000", "1001"])
        #expect(saved.pendingRegistration?.phase == .enablingTwoFA)
        if alreadyAwaitingCode {
            #expect(saved.pendingRegistration?.requestedAt == pending.requestedAt)
        } else {
            #expect(try #require(saved.pendingRegistration?.requestedAt) > pending.requestedAt!)
        }
        #expect(mailView.messageLoads == 1)
        coordinator.stop()
        for _ in 0..<100 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!coordinator.isRunning)
    }
}
