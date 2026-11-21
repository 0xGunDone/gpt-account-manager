import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class CodexConsentFixtureWebView: WKWebView {
    var reportedURL: URL?
    override var url: URL? { reportedURL ?? super.url }
}

@MainActor
@Suite(.serialized)
struct CodexConsentFormTests {
    private let email = "owner@example.com"
    private let consentPath = "/sign-in-with-chatgpt/codex/consent"

    private func session() -> BrowserSession {
        _ = NSApplication.shared
        return BrowserSession(dataStore: .nonPersistent()) { configuration in
            CodexConsentFixtureWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        }
    }

    private func load(_ html: String, in session: BrowserSession, path: String? = nil, host: String = "auth.openai.com") async throws {
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: "https://\(host)\(path ?? consentPath)"))
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        #expect(!session.webView.isLoading)
    }

    private func consent(
        workspaces: String, email: String = "owner@example.com", extra: String = "",
        buttonAttributes: String = "", heading: String = "Sign in to Codex with ChatGPT"
    ) -> String {
        """
        <title>\(heading) - OpenAI</title>
        <div id="consent">
          <div>\(heading)</div><span>\(email)</span>
          <p>Choose a workspace</p><div role="radiogroup">\(workspaces)</div>
          <button id="continue" type="button" \(buttonAttributes)
            onclick="document.body.dataset.submitted=String(Number(document.body.dataset.submitted||0)+1)">Continue</button>
          \(extra)
        </div>
        """
    }

    private func namedFormConsent(
        email: String = "owner@example.com", selected: Bool = true, labelAttributes: String = ""
    ) -> String {
        """
        <title>Вход в Codex с помощью ChatGPT - OpenAI</title>
        <form aria-label="Вход в Codex с помощью ChatGPT"
          onsubmit="event.preventDefault();document.body.dataset.submitted=String(Number(document.body.dataset.submitted||0)+1)">
          <span>\(email)</span><p>Выберите рабочую область</p>
          <label id="personal-label" \(labelAttributes)
            onclick="if(event.target===this)document.body.dataset.labelClicked='1'">
            <input id="personal" type="radio" name="workspace" style="opacity:0;width:12px;height:12px"
              \(selected ? "checked disabled" : "") onchange="document.getElementById('continue').disabled=false">
            <span aria-hidden="true">O</span><span>Личная учетная запись</span>
          </label>
          <button id="continue" type="submit" \(selected ? "" : "disabled")>Продолжить</button>
        </form>
        """
    }

    @Test func namedConsentFormSubmitsSelectedStyledPersonalWorkspace() async throws {
        let session = session()
        try await load(namedFormConsent(), in: session)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .submitted)
        #expect(try await session.evaluate("document.body.dataset.submitted") as? String == "1")
    }

    @Test func namedConsentFormSelectsStyledRadioThroughVisibleLabelBeforeSubmitting() async throws {
        let session = session()
        try await load(namedFormConsent(selected: false), in: session)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .selected)
        #expect(try await session.evaluate("document.body.dataset.labelClicked") as? String == "1")
        #expect(try await session.evaluate("document.getElementById('personal').checked") as? Bool == true)
        #expect(try await session.evaluate("document.body.dataset.submitted === undefined") as? Bool == true)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .submitted)
        #expect(try await session.evaluate("document.body.dataset.submitted") as? String == "1")
    }

    @Test func namedConsentFormRejectsWrongIdentityAndHiddenWorkspaceLabels() async throws {
        let session = session()
        let fixtures = [
            namedFormConsent(email: "other@example.com", selected: false),
            namedFormConsent(selected: false, labelAttributes: "hidden"),
            namedFormConsent(selected: false, labelAttributes: "aria-hidden='true'"),
            namedFormConsent(selected: false, labelAttributes: "style='opacity:0'"),
        ]
        for html in fixtures {
            try await load(html, in: session)
            #expect(try await CodexConsentForm.advance(email: email, in: session) == .notFound)
            #expect(try await session.evaluate("document.getElementById('personal').checked") as? Bool == false)
            #expect(try await session.evaluate("document.body.dataset.labelClicked === undefined && document.body.dataset.submitted === undefined") as? Bool == true)
        }
    }

    @Test(arguments: ["input", "role", "labelledRole"])
    func englishPersonalWorkspaceIsSelectedBeforeDelayedContinue(kind: String) async throws {
        let session = session()
        let enable = "setTimeout(() => document.getElementById('continue').disabled=false, 60)"
        let workspace: String
        switch kind {
        case "input":
            workspace = "<label><input id='personal' type='radio' name='workspace' onchange=\"\(enable)\">Personal account</label>"
        case "role":
            workspace = "<button id='personal' type='button' role='radio' aria-checked='false' onclick=\"this.setAttribute('aria-checked','true');\(enable)\">Personal account</button>"
        default:
            workspace = "<button id='personal' type='button' role='radio' aria-checked='false' aria-labelledby='personal-label' style='width:20px;height:20px' onclick=\"this.setAttribute('aria-checked','true');\(enable)\"></button><span id='personal-label'>Personal account</span>"
        }
        try await load(consent(workspaces: workspace, buttonAttributes: "disabled"), in: session)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .selected)
        #expect(try await session.evaluate("document.body.dataset.submitted === undefined") as? Bool == true)
        #expect(try await session.evaluate("document.getElementById('personal').checked === true || document.getElementById('personal').getAttribute('aria-checked') === 'true'") as? Bool == true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .submitted)
        #expect(try await session.evaluate("document.body.dataset.submitted") as? String == "1")
    }

    @Test(arguments: ["input", "role"])
    func uniquePersonalWorkspaceReplacesOrganizationSelection(kind: String) async throws {
        let session = session()
        let workspaces = kind == "input" ? """
        <label><input type="radio" name="workspace" checked>Organization one</label>
        <label><input id="personal" type="radio" name="workspace">Personal account</label>
        <label><input type="radio" name="workspace">Organization two</label>
        """ : """
        <button type="button" role="radio" aria-checked="true">Organization one</button>
        <button id="personal" type="button" role="radio" aria-checked="false" onclick="document.querySelectorAll('[role=radio]').forEach(e=>e.setAttribute('aria-checked','false'));this.setAttribute('aria-checked','true')">Personal account</button>
        <button type="button" role="radio" aria-checked="false">Organization two</button>
        """
        try await load(consent(workspaces: workspaces), in: session)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .selected)
        #expect(try await session.evaluate("document.body.dataset.submitted === undefined") as? Bool == true)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .submitted)
        #expect(try await session.evaluate("document.body.dataset.submitted") as? String == "1")
    }

    @Test(arguments: ["Личная учетная запись", "Личная учётная запись"])
    func russianPersonalWorkspaceCanBeSelected(label: String) async throws {
        let session = session()
        let html = consent(
            workspaces: "<label><input type='radio' name='workspace'>\(label)</label>",
            heading: "Вход в Codex с помощью ChatGPT")
            .replacingOccurrences(of: ">Continue<", with: ">Продолжить<")
        try await load(html, in: session)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .selected)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .submitted)
    }

    @Test func selectedPersonalWorkspaceSubmitsWithOtherUnselectedOrganizations() async throws {
        let session = session()
        try await load(consent(workspaces: """
        <label><input type="radio" name="workspace" checked disabled>Personal account</label>
        <label><input type="radio" name="workspace">Organization one</label>
        """), in: session)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .submitted)
        #expect(try await session.evaluate("document.body.dataset.submitted") as? String == "1")
    }

    @Test func selectedWorkspaceWaitsForEnabledContinue() async throws {
        let session = session()
        try await load(consent(workspaces: "<label><input type='radio' checked>Personal account</label>", buttonAttributes: "disabled"), in: session)
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .waiting)
        _ = try await session.evaluate("document.querySelector('button').disabled=false")
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .submitted)
    }

    @Test func ambiguousMissingOrDisabledPersonalWorkspaceRequiresManualAction() async throws {
        let session = session()
        let fixtures = [
            "<label><input type='radio' name='workspace'>Organization one</label><label><input type='radio' name='workspace'>Organization two</label>",
            "<label><input type='radio' name='workspace'>Personal account</label><label><input type='radio' name='workspace'>Personal account</label>",
            "<label><input type='radio' name='workspace' disabled>Personal account</label>",
            "<button type='button' role='radio' aria-checked='true'>Personal account</button><button type='button' role='radio' aria-checked='true'>Organization one</button>",
            "<button role='radio' aria-checked='false'>Personal account</button>",
            "<button type='button' role='radio' aria-checked='false' aria-labelledby='hidden-label'>Choose</button><span id='hidden-label' hidden>Personal account</span>",
            "<label style='opacity:0'><input type='radio' name='workspace' checked>Personal account</label>",
            "<input id='hidden-radio' type='radio' hidden checked><label for='hidden-radio'>Personal account</label>",
            "<input id='hidden-radio' type='radio' aria-hidden='true' checked><label for='hidden-radio'>Personal account</label>",
            "<input id='hidden-radio' type='radio' style='display:none' checked><label for='hidden-radio'>Personal account</label>",
            "<input id='hidden-radio' type='radio' style='visibility:hidden' checked><label for='hidden-radio'>Personal account</label>",
        ]
        for workspaces in fixtures {
            try await load(consent(workspaces: workspaces), in: session)
            #expect(try await CodexConsentForm.advance(email: email, in: session) == .notFound)
            #expect(try await session.evaluate("document.body.dataset.submitted === undefined") as? Bool == true)
        }
    }

    @Test func identityControlsAndDestinationsAreCheckedBeforeSelectingWorkspace() async throws {
        let session = session()
        let workspace = "<label><input id='personal' type='radio' name='workspace'>Personal account</label>"
        let fixtures = [
            consent(workspaces: workspace, email: "other@example.com"),
            consent(workspaces: workspace, email: "owner@example.com.evil"),
            consent(workspaces: workspace, email: "<span hidden>owner@example.com</span>"),
            consent(workspaces: workspace, email: "<span aria-hidden='true'>owner@example.com</span>"),
            consent(workspaces: workspace, email: "<span style='opacity:0'>owner@example.com</span>"),
            "<p>owner@example.com</p>" + consent(workspaces: workspace, email: "other@example.com"),
            consent(workspaces: workspace, extra: "<button>Continue</button>"),
            consent(workspaces: workspace, extra: "<input type='password'>"),
            consent(workspaces: workspace, buttonAttributes: "formaction='https://other.example/submit'"),
            "<form action='https://other.example/submit'>" + consent(workspaces: workspace) + "</form>",
            consent(workspaces: workspace.replacingOccurrences(of: "id='personal'", with: "id='personal' form='external'")) + "<form id='external' action='https://other.example/submit'></form>",
            consent(workspaces: workspace).replacingOccurrences(of: "<title>Sign in to Codex with ChatGPT - OpenAI</title>", with: "<title>Another App - OpenAI</title>"),
            consent(workspaces: workspace, heading: "Sign in to Other App with ChatGPT"),
        ]
        for html in fixtures {
            try await load(html, in: session)
            #expect(try await CodexConsentForm.advance(email: email, in: session) == .notFound)
            #expect(try await session.evaluate("document.getElementById('personal').checked") as? Bool == false)
            #expect(try await session.evaluate("document.body.dataset.submitted === undefined") as? Bool == true)
        }
    }

    @Test func nativeAndDOMConsentLocationsMustMatch() async throws {
        let session = session()
        let html = consent(workspaces: "<label><input type='radio' checked>Personal account</label>")
        try await load(html, in: session, path: "/some-other-consent")
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .notFound)
        let webView = try #require(session.webView as? CodexConsentFixtureWebView)
        webView.reportedURL = URL(string: "https://auth.openai.com\(consentPath)")
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .notFound)
        #expect(try await session.evaluate("document.body.dataset.submitted === undefined") as? Bool == true)
        webView.reportedURL = nil
        try await load(html, in: session, host: "chatgpt.com")
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .notFound)
    }

    @Test func legacyCodexConsentRequiresItsKnownRouteAndMatchingIdentity() async throws {
        let session = session()
        let html = """
        <main><h1>Sign in to Codex</h1><p>owner@example.com</p>
        <form onsubmit="event.preventDefault();document.body.dataset.submitted='1'"><button>Allow</button></form></main>
        """
        try await load(html, in: session, path: "/codex/consent")
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .submitted)
        #expect(try await session.evaluate("document.body.dataset.submitted") as? String == "1")
        try await load(html, in: session, path: "/oauth/consent")
        #expect(try await CodexConsentForm.advance(email: email, in: session) == .notFound)
        #expect(try await session.evaluate("document.body.dataset.submitted === undefined") as? Bool == true)
    }
}
