import AppKit
import SwiftUI

@main
struct GPTAccountManagerApp: App {
    @State private var mailbox = MailRuMailbox()
    @State private var proxies = ProxyStore()
    @State private var update = GitStartupUpdate()

    var body: some Scene {
        WindowGroup("GPT Account Manager") {
            afterUpdate { ContentView(mailbox: mailbox, proxies: proxies) }
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1080, height: 720)
        Window("Почта Mail.ru", id: "mailbox") {
            afterUpdate { MailboxView(mailbox: mailbox) }
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1050, height: 760)
    }

    @ViewBuilder
    private func afterUpdate<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if update.phase == .ready {
            content()
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(update.phase.title)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear(perform: update.start)
        }
    }
}
