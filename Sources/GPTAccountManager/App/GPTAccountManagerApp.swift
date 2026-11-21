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
            VStack(spacing: 16) {
                Text(update.phase.title)
                    .font(.headline)
                switch update.phase {
                case .available:
                    Text("Приложение загрузит исходники стабильного релиза, соберёт новую версию и перезапустится.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Позже", action: update.useInstalledVersion)
                            .keyboardShortcut(.cancelAction)
                        Button("Обновить", action: update.installAvailableRelease)
                            .keyboardShortcut(.defaultAction)
                    }
                case .checkFailed, .failed:
                    Text("Можно продолжить работу в установленной версии.")
                        .foregroundStyle(.secondary)
                    Button("Продолжить", action: update.useInstalledVersion)
                        .keyboardShortcut(.defaultAction)
                case .checking:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(update.phase.title)
                    Button("Пропустить проверку", action: update.useInstalledVersion)
                default:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(update.phase.title)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear(perform: update.start)
        }
    }
}
