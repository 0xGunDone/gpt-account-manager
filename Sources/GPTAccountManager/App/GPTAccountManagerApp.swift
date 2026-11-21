import AppKit
import SwiftUI

@main
struct GPTAccountManagerApp: App {
    @State private var mailbox = MailRuMailbox()
    @State private var proxies = ProxyStore()
    var body: some Scene {
        WindowGroup("GPT Account Manager") {
            ContentView(mailbox: mailbox, proxies: proxies)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1080, height: 720)
        Window("Почта Mail.ru", id: "mailbox") {
            MailboxView(mailbox: mailbox)
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1050, height: 760)
    }
}
