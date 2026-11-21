import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class RegistrationFixtureWebView: WKWebView {
    var fixtureHTML = "<h1>Verify you are human</h1><script>window.fetch=async()=>({ok:true,json:async()=>({})});</script>"
    var loads = 0
    var reportedURL: URL?
    override var url: URL? { reportedURL ?? super.url }

    override func load(_ request: URLRequest) -> WKNavigation? {
        loads += 1
        return super.loadHTMLString(fixtureHTML, baseURL: request.url)
    }
}

@MainActor
@Suite(.serialized)
struct RegistrationCoordinatorTests {
    private let configuredPassword = "registration-fixture-password"

    private func fixture(transitionWaitInterval: Duration = .seconds(45)) -> (AccountStore, RegistrationCoordinator, BrowserSession, RegistrationFixtureWebView) {
        _ = NSApplication.shared
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            RegistrationFixtureWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        return (store, RegistrationCoordinator(store: store, browser: browser, mailbox: MailRuMailbox(),
                                               configuredPassword: configuredPassword,
                                               transitionWaitInterval: transitionWaitInterval),
                session, session.webView as! RegistrationFixtureWebView)
    }

    private func waitUntilPaused(_ coordinator: RegistrationCoordinator) async throws {
        for _ in 0..<300 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        try #require(!coordinator.isRunning)
    }

    private func waitForMessage(_ text: String, in coordinator: RegistrationCoordinator) async throws {
        for _ in 0..<100 where !coordinator.message.contains(text) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(coordinator.message.contains(text))
    }

    @Test func startStopAndResumePreserveSingleDraftAndItsSession() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try coordinator.start(email: "new@icloud.com")
        let original = try #require(store.accounts.first)
        let profile = try #require(original.pendingRegistration)
        #expect(profile.fullName.split(separator: " ").count == 2 && (21...45).contains(profile.age))
        #expect(coordinator.isRunning)
        try coordinator.start(email: "second@icloud.com")
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        #expect(store.accounts == [original])
        #expect(web.loads == 0)
        #expect(coordinator.activeSession === session)

        coordinator.resume(id: original.id)
        try await waitForMessage("продолжится автоматически", in: coordinator)
        #expect(coordinator.isRunning)
        #expect(store.accounts == [original] && store.groups.isEmpty)
        #expect(coordinator.message.contains("проверку"))
        #expect(web.loads == 1)
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        #expect(coordinator.message.contains("Остановлено"))
        coordinator.resume(id: original.id)
        try await waitForMessage("продолжится автоматически", in: coordinator)
        #expect(web.loads == 1 && store.accounts[0].pendingRegistration == profile)
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        coordinator.newRegistration()
        #expect(coordinator.accountID == nil && coordinator.activeSession == nil)
        #expect(store.accounts == [original])
        coordinator.show(id: original.id)
        #expect(coordinator.activeSession === session && coordinator.accountID == original.id)
        #expect(store.accounts[0].browserStoreID == original.browserStoreID)
    }

    @Test func authenticatedPageWithoutPasswordCheckpointCannotPublishReadyAccount() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <h1>ChatGPT</h1><script>
        window.fetch=async()=>({ok:true,json:async()=>({user:{email:'new@icloud.com',id:'synthetic-user'}})});
        </script>
        """
        try coordinator.start(email: "new@icloud.com")
        try await waitUntilPaused(coordinator)
        let draft = try #require(store.accounts.first)
        #expect(draft.pendingRegistration?.passwordWasSubmitted == false)
        #expect(draft.status == .needsRecovery && draft.totpSecret.isEmpty && draft.groupID == nil)
        #expect(store.groups.isEmpty && coordinator.message.contains("пароль"))
        #expect(coordinator.activeSession === session)
    }

    @Test(arguments: ["network", "server", "navigation"])
    func transientSessionProbeContinuesSameDraftWithoutAnotherLogin(behavior: String) async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <h1>Loading</h1><script>
        window.probes = 0;
        window.fetch = async () => {
          if (++window.probes === 1) {
            if ('\(behavior)' === 'network') throw new TypeError('Temporary network failure');
            if ('\(behavior)' === 'server') return {ok:false,status:503};
            history.replaceState({}, '', '/auth/login_with');
          }
          return {ok:true,json:async()=>({user:{email:'new@icloud.com',id:'fixture-user'}})};
        };
        </script>
        """
        try coordinator.start(email: "new@icloud.com")
        try await waitUntilPaused(coordinator)
        #expect(coordinator.message.contains("пароль ещё не установлен"))
        #expect(try await session.evaluate("window.probes") as? Int ?? 0 >= 2)
        #expect(web.loads == 1 && coordinator.activeSession === session)
        #expect(store.accounts.count == 1 && store.accounts[0].pendingRegistration?.passwordWasSubmitted == false)
    }

    @Test func wrongSessionIdentityStillStopsImmediately() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <script>window.probes=0;window.fetch=async()=>{window.probes++;return {ok:true,json:async()=>({user:{email:'other@icloud.com'}})}};</script>
        """
        try coordinator.start(email: "new@icloud.com")
        try await waitUntilPaused(coordinator)
        #expect(try await session.evaluate("window.probes") as? Int == 1)
        #expect(store.accounts.count == 1 && store.accounts[0].pendingRegistration?.passwordWasSubmitted == false)
        #expect(!coordinator.isRunning)
    }

    @Test func completedHumanChallengeAutomaticallyContinuesWithoutAnotherResume() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <h1>Verify you are human</h1><script>
        window.fixtureIdentity = false;
        window.fetch = async () => ({ok:true,json:async () => window.fixtureIdentity
          ? {user:{email:'new@icloud.com',id:'synthetic-user'}} : {}});
        </script>
        """
        try coordinator.start(email: "new@icloud.com")
        try await waitForMessage("продолжится автоматически", in: coordinator)
        let draft = try #require(store.accounts.first)
        #expect(coordinator.isRunning)
        _ = try await session.evaluate("(() => { window.fixtureIdentity = true; document.body.innerHTML = '<h1>ChatGPT</h1>'; return true; })()")
        try await waitUntilPaused(coordinator)
        #expect(coordinator.message.contains("пароль ещё не установлен"))
        #expect(store.accounts == [draft] && store.groups.isEmpty)
        #expect(web.loads == 1 && coordinator.activeSession === session)
    }

    @Test func delayedProfileTransitionWaitsBeyondOldTimeoutWithoutResubmitting() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <form onsubmit="event.preventDefault(); window.profileSubmissions += 1;
          window.submittedName = document.querySelector('[name=name]').value;
          window.submittedAge = document.querySelector('[name=age]').value;
          history.replaceState({}, '', '/about-you?state=changed');
          setTimeout(() => { document.body.innerHTML = '<h1>Loading</h1>'; }, 900);
          setTimeout(() => { document.body.innerHTML = '<h1>Verify you are human</h1>'; }, 8000);">
          <input name=name><input name=age type=number><button>Continue</button>
        </form><script>window.profileSubmissions = 0;</script>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        var profile = try #require(draft.pendingRegistration)
        profile.passwordWasSubmitted = true
        profile.phase = .profile
        try store.checkpointRegistration(id: draft.id, registration: profile)
        _ = session.load(URL(string: "https://auth.openai.com/about-you")!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        coordinator.resume(id: draft.id)
        for _ in 0..<140 where !coordinator.message.contains("продолжится автоматически") {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(coordinator.isRunning && coordinator.message.contains("продолжится автоматически"))
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        #expect(try await session.evaluate("window.profileSubmissions") as? Int == 1)
        #expect(try await session.evaluate("window.submittedName") as? String == profile.fullName)
        #expect(try await session.evaluate("window.submittedAge") as? String == String(profile.age))
        #expect(store.accounts.first?.pendingRegistration == profile && store.groups.isEmpty)
    }

    @Test(arguments: [false, true])
    func birthdayProfilePersistsDateBeforeSubmittingAndReusesSavedDate(preexisting: Bool) async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <form onsubmit="event.preventDefault();window.profileSubmissions++;
          window.submittedName=document.querySelector('[name=name]').value;
          window.submittedDate=document.querySelector('[name=birthdate]').value;
          document.body.innerHTML='<h1>Verify you are human</h1>'">
          <label>Full name<input name=name></label>
          <label>Date of birth<input name=birthdate type=date></label>
          <button>Continue</button>
        </form><script>window.profileSubmissions=0;</script>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 33, password: "fixture")
        var pending = try #require(draft.pendingRegistration)
        pending.passwordWasSubmitted = true
        pending.phase = .profile
        if preexisting { pending.birthDate = "1993-02-15" }
        try store.checkpointRegistration(id: draft.id, registration: pending)
        _ = session.load(URL(string: "https://auth.openai.com/about-you")!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        coordinator.resume(id: draft.id)
        for _ in 0..<100 where !coordinator.message.contains("продолжится автоматически") {
            try await Task.sleep(for: .milliseconds(50))
        }
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        let saved = try #require(store.accounts.first?.pendingRegistration)
        let date = try #require(saved.birthDate)
        #expect(date == (preexisting ? "1993-02-15" : PendingRegistration.birthDate(forAge: 33)))
        #expect(try await session.evaluate("window.submittedDate") as? String == date)
        #expect(try await session.evaluate("window.submittedName") as? String == pending.fullName)
        #expect(try await session.evaluate("window.profileSubmissions") as? Int == 1)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first?.pendingRegistration?.birthDate == date)
        #expect(saved.age == pending.age && saved.fullName == pending.fullName && store.groups.isEmpty)
    }

    @Test func slowTransitionKeepsObservingAndSubmittingOnlyOnceUntilStopped() async throws {
        let (store, coordinator, session, web) = fixture(transitionWaitInterval: .milliseconds(100))
        defer { coordinator.stop(); session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <script>window.submits=0;</script><main>Loading</main>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        var profile = try #require(draft.pendingRegistration)
        profile.passwordWasSubmitted = true
        profile.phase = .profile
        try store.checkpointRegistration(id: draft.id, registration: profile)
        _ = session.load(URL(string: "https://auth.openai.com/about-you")!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        coordinator.resume(id: draft.id)
        try await Task.sleep(for: .milliseconds(900))
        try #require(coordinator.isRunning)
        #expect(coordinator.message.contains("автоматически"))
        #expect(coordinator.accountID == draft.id && coordinator.activeSession === session)
        _ = try await session.evaluate("""
        (() => {
          document.body.innerHTML = `<form onsubmit="event.preventDefault();window.submits++">
            <input name="name"><input name="age" type="number"><button>Continue</button></form>`;
          return true;
        })()
        """)
        for _ in 0..<80 {
            if try await session.evaluate("window.submits") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(1600))
        #expect(coordinator.isRunning)
        #expect(try await session.evaluate("window.submits") as? Int == 1)
        #expect(store.accounts.count == 1 && store.groups.isEmpty && web.loads == 1)
        _ = try await session.evaluate("document.body.innerHTML='<h1>Verify you are human</h1>'")
        try await waitForMessage("Пройдите проверку", in: coordinator)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(coordinator.isRunning && coordinator.message.contains("Пройдите проверку"))
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        #expect(coordinator.message.contains("Остановлено"))
        #expect(store.accounts.first?.pendingRegistration == profile && coordinator.hasPendingBatch)
    }

    @Test func stopDuringOrdinaryTransitionKeepsDraftAndStopsActions() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <script>window.clicks = 0; window.fetch=async()=>({ok:true,json:async()=>({})});</script>
        <button onclick="window.clicks += 1">Sign up</button>
        """
        try coordinator.start(email: "new@icloud.com")
        try await waitForMessage("Открывается форма регистрации", in: coordinator)
        for _ in 0..<100 {
            if try await session.evaluate("window.clicks") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let draft = try #require(store.accounts.first)
        #expect(coordinator.isRunning)
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await session.evaluate("window.clicks") as? Int == 1)
        #expect(coordinator.message.contains("Остановлено"))
        #expect(store.accounts == [draft] && store.groups.isEmpty)
    }

    @Test func temporarilyDisabledProfileSubmitRetriesWithoutNewProfile() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <form onsubmit="event.preventDefault(); window.profileSubmissions += 1;
          window.submittedName = document.querySelector('[name=name]').value;
          document.body.innerHTML = '<h1>Verify you are human</h1>';">
          <input name=name><input name=age type=number><button disabled>Continue</button>
        </form><script>
        window.profileSubmissions = 0;
        setTimeout(() => document.querySelector('button').disabled = false, 2200);
        </script>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        var profile = try #require(draft.pendingRegistration)
        profile.passwordWasSubmitted = true
        profile.phase = .profile
        try store.checkpointRegistration(id: draft.id, registration: profile)
        _ = session.load(URL(string: "https://auth.openai.com/about-you")!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        coordinator.resume(id: draft.id)
        try await waitForMessage("продолжится автоматически", in: coordinator)
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        #expect(try await session.evaluate("window.profileSubmissions") as? Int == 1)
        #expect(try await session.evaluate("window.submittedName") as? String == profile.fullName)
        #expect(store.accounts.first?.pendingRegistration == profile && store.groups.isEmpty)
    }

    @Test func ignoredProfileClickRetriesUntilFormSubmitsWithoutManualResume() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <form onsubmit="event.preventDefault();window.submits++;document.body.innerHTML='<h1>Verify you are human</h1>'">
          <input name="name" onblur="window.committedName=this.value">
          <input name="age" type="number" onblur="window.committedAge=this.value">
          <button onclick="if(++window.clicks===1)event.preventDefault()">Continue</button>
        </form><script>window.clicks=0;window.submits=0;</script>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        var profile = try #require(draft.pendingRegistration)
        profile.passwordWasSubmitted = true
        profile.phase = .profile
        try store.checkpointRegistration(id: draft.id, registration: profile)
        _ = session.load(URL(string: "https://auth.openai.com/about-you")!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        coordinator.resume(id: draft.id)
        try await waitForMessage("продолжится автоматически", in: coordinator)
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        #expect(try await session.evaluate("window.clicks") as? Int == 2)
        #expect(try await session.evaluate("window.submits") as? Int == 1)
        #expect(try await session.evaluate("window.committedName") as? String == profile.fullName)
        #expect(try await session.evaluate("window.committedAge") as? String == String(profile.age))
        #expect(store.accounts.first?.pendingRegistration == profile && store.groups.isEmpty)
    }

    @Test func registrationRefusalGetsOnlyOneRetryAcrossResumeAndReload() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <script>window.submits=0;</script>
        <form onsubmit="event.preventDefault();window.submits++;document.getElementById('error').hidden=false">
          <input name="name"><input name="age" type="number"><button>Continue</button>
          <p id="error" hidden>Мы не можем создать вашу учетную запись из-за наших условий использования</p>
        </form>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        var profile = try #require(draft.pendingRegistration)
        profile.passwordWasSubmitted = true
        profile.phase = .profile
        try store.checkpointRegistration(id: draft.id, registration: profile)
        _ = session.load(URL(string: "https://auth.openai.com/about-you")!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        coordinator.resume(id: draft.id)
        try await waitUntilPaused(coordinator)
        #expect(coordinator.message.contains(RegistrationForm.rejectionMessage))
        #expect(try await session.evaluate("window.submits") as? Int == 2)
        let saved = try #require(store.accounts.first)
        #expect(saved.pendingRegistration?.profileRetryUsed == true)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts == [saved])
        coordinator.resume(id: draft.id)
        try await waitUntilPaused(coordinator)
        #expect(try await session.evaluate("window.submits") as? Int == 2)
        #expect(store.accounts == [saved] && store.groups.isEmpty)
        #expect(store.accounts.first?.pendingRegistration?.fullName == profile.fullName)
        #expect(store.accounts.first?.pendingRegistration?.age == profile.age)
        let replacement = RegistrationCoordinator(store: reloaded,
            browser: ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session })),
            mailbox: MailRuMailbox())
        replacement.resume(id: draft.id)
        try await waitUntilPaused(replacement)
        #expect(try await session.evaluate("window.submits") as? Int == 2)
    }

    @Test func profileRetryUsesSameValuesAndContinuesWhenSecondSubmissionSucceeds() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <script>window.submits=0;window.values=[];</script>
        <form onsubmit="event.preventDefault();window.submits++;window.values.push([...document.querySelectorAll('input')].map(e=>e.value));
          if(window.submits===1)document.getElementById('error').hidden=false;
          else document.body.innerHTML='<h1>Verify you are human</h1>'">
          <input name="name"><input name="age" type="number"><button>Continue</button>
          <p id="error" hidden>Мы не можем создать вашу учетную запись из-за наших условий использования</p>
        </form>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        var profile = try #require(draft.pendingRegistration)
        profile.passwordWasSubmitted = true
        profile.phase = .profile
        try store.checkpointRegistration(id: draft.id, registration: profile)
        _ = session.load(URL(string: "https://auth.openai.com/about-you")!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        coordinator.resume(id: draft.id)
        try await waitForMessage("продолжится автоматически", in: coordinator)
        #expect(try await session.evaluate("window.submits") as? Int == 2)
        #expect(try await session.evaluate("JSON.stringify(window.values)") as? String == "[[\"Fixture Person\",\"29\"],[\"Fixture Person\",\"29\"]]")
        #expect(store.accounts.first?.id == draft.id && store.accounts.first?.browserStoreID == draft.browserStoreID)
    }

    @Test func resumedProfileDoesNotSubmitThirdTimeWhenErrorDisappears() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <script>window.submits=0;</script>
        <form onsubmit="event.preventDefault();window.submits++;document.querySelector('p').remove()">
          <input name="name" value="Fixture Person"><input name="age" type="number" value="29"><button>Continue</button>
          <p>We cannot create your account due to our terms of use.</p>
        </form>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        var profile = try #require(draft.pendingRegistration)
        profile.passwordWasSubmitted = true
        profile.phase = .profile
        try store.checkpointRegistration(id: draft.id, registration: profile)
        _ = session.load(URL(string: "https://auth.openai.com/about-you")!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        coordinator.resume(id: draft.id)
        for _ in 0..<100 where store.accounts.first?.pendingRegistration?.profileRetryUsed != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .seconds(3))
        #expect(try await session.evaluate("window.submits") as? Int == 1)
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        coordinator.resume(id: draft.id)
        try await Task.sleep(for: .seconds(1))
        #expect(try await session.evaluate("window.submits") as? Int == 1)
    }

    @Test func refusalOutsideProfileDoesNotRetryRegistration() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <script>window.submits=0;</script>
        <form onsubmit="event.preventDefault();window.submits++">
          <input type="password"><button>Continue</button>
          <p>We cannot create your account due to our terms of use.</p>
        </form>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        _ = session.load(URL(string: "https://auth.openai.com/create-account/password")!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        coordinator.resume(id: draft.id)
        try await waitUntilPaused(coordinator)
        #expect(coordinator.message == RegistrationForm.rejectionMessage)
        #expect(try await session.evaluate("window.submits") as? Int == 0)
        #expect(store.accounts == [draft])
    }

    @Test func everyNewStartCreatesRandomProfileWithoutChangingOlderDraft() async throws {
        let (store, coordinator, _, _) = fixture()
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let existing = try store.beginRegistration(email: "old@icloud.com", fullName: "Manually Chosen", age: 67, password: "fixture")
        coordinator.show(id: existing.id)
        coordinator.newRegistration()
        try coordinator.start(email: "new@icloud.com")
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        let first = try #require(store.accounts.last)
        coordinator.newRegistration()
        try coordinator.start(email: "second@icloud.com")
        coordinator.stop()
        try await waitUntilPaused(coordinator)
        let second = try #require(store.accounts.last)
        #expect(first.id != second.id)
        let bothUseConfiguredPassword = [first, second].allSatisfy { $0.password == configuredPassword }
        #expect(bothUseConfiguredPassword)
        for account in [first, second] {
            let profile = try #require(account.pendingRegistration)
            #expect(profile.fullName != "Manually Chosen" && profile.fullName.split(separator: " ").count == 2)
            #expect((21...45).contains(profile.age) && profile.termsAccepted)
        }
        #expect(store.accounts.first == existing && store.accounts[1] == first && store.groups.isEmpty)
    }

    @Test func invalidResumeAndDuplicateStartDoNotReplaceExistingDraft() throws {
        let (store, coordinator, session, _) = fixture()
        defer { session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Test Person", age: 28, password: "fixture")
        coordinator.show(id: draft.id)
        coordinator.resume(id: UUID())
        #expect(!coordinator.isRunning && coordinator.activeSession === session)
        #expect(throws: AccountStoreError.duplicateAccountEmail) {
            try coordinator.start(email: draft.email.uppercased())
        }
        #expect(store.accounts == [draft] && store.groups.isEmpty)
        #expect(coordinator.accountID == draft.id)
    }

    @Test(arguments: [false, true])
    func resumeWaitsForSubmittedPasswordTransitionWithoutResubmitting(staleRoute: Bool) async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        web.fixtureHTML = """
        <form onsubmit="event.preventDefault(); window.passwordSubmissions += 1">
          <input type=password><button>Continue</button>
        </form><script>
        window.passwordSubmissions = 0;
        setTimeout(() => {
          history.replaceState({}, '', '/email-verification');
          document.body.innerHTML = '<main><p>We sent a code to new@icloud.com</p><form><input name=code autocomplete=one-time-code><button>Continue</button></form></main>';
        }, 900);
        </script>
        """
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        var pending = try #require(draft.pendingRegistration)
        pending.passwordWasSubmitted = true
        pending.phase = .awaitingEmailCode
        // Missing synthetic mail request stops at code handling without opening a real mailbox.
        pending.requestedAt = nil
        try store.checkpointRegistration(id: draft.id, registration: pending)
        let path = staleRoute ? "/log-in/password" : "/create-account/password"
        _ = session.load(URL(string: "https://auth.openai.com" + path)!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        if staleRoute { web.reportedURL = URL(string: "https://auth.openai.com/email-verification") }
        coordinator.resume(id: draft.id)
        try await waitUntilPaused(coordinator)
        #expect(coordinator.message.contains("Не сохранён момент запроса письма"))
        #expect(try await session.evaluate("window.passwordSubmissions") as? Int == 0)
        #expect(store.accounts.first?.pendingRegistration == pending)
    }

    @Test func initialPageResumesSubmittedPasswordAtEmailVerification() async throws {
        let (store, coordinator, session, web) = fixture()
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let draft = try store.beginRegistration(email: "new@icloud.com", fullName: "Fixture Person", age: 29, password: "fixture")
        var pending = try #require(draft.pendingRegistration)
        pending.passwordWasSubmitted = true
        pending.phase = .awaitingEmailCode
        try store.checkpointRegistration(id: draft.id, registration: pending)
        coordinator.resume(id: draft.id)
        for _ in 0..<100 where web.loads == 0 || session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.webView.url?.absoluteString == "https://auth.openai.com/email-verification")
        #expect(web.loads == 1)
        #expect(store.accounts.first?.pendingRegistration == pending)
        coordinator.stop()
        try await waitUntilPaused(coordinator)
    }
}
