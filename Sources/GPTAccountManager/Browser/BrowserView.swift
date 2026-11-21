import SwiftUI
import WebKit

struct BrowserAddressBar: View {
    @ObservedObject var session: BrowserSession
    let navigationDisabled: Bool
    @State private var text = ""
    @State private var error: String?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("https://…", text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Адрес страницы")
                    .focused($editing)
                    .onSubmit(navigate)
                    .disabled(navigationDisabled)
                Button("Перейти", action: navigate)
                    .disabled(navigationDisabled || text.isEmpty)
                Button("Копировать URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.addressText, forType: .string)
                }
                .disabled(session.addressText.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { text = session.addressText }
        .onChange(of: session.addressText) { _, value in
            if !editing || session.callbackURL != nil { text = value }
        }
    }

    private func navigate() {
        guard !navigationDisabled else { return }
        if session.navigateAddress(text) {
            editing = false
            text = session.addressText
            error = nil
        } else {
            error = "Введите полный адрес с https:// или http://."
        }
    }
}

struct BrowserStatusView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        if let message = session.operationMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let message = session.oauthMessage ?? session.pageLoadMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct BrowserView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        BrowserSurface(session: session)
            .id(ObjectIdentifier(session.webView))
    }
}

struct BrowserMount: Identifiable {
    let id: UUID
    let session: BrowserSession
}

struct BackgroundBrowserPool: View {
    let mounts: [BrowserMount]

    var body: some View {
        ZStack {
            ForEach(mounts) { mount in
                BrowserView(session: mount.session)
                    .frame(width: 1, height: 1)
            }
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BrowserSurface: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
