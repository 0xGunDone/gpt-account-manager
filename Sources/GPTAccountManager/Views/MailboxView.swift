import SwiftUI
import WebKit

struct MailboxView: View {
    let mailbox: MailRuMailbox
    @State private var address = ""
    @State private var addressError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    TextField("Ящик Mail.ru для пересылки", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .accessibilityLabel("Ящик Mail.ru для пересылки")
                        .onSubmit(saveAddress)
                    Button("Сохранить", action: saveAddress)
                        .disabled(address == mailbox.expectedMailbox)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Button("Проверить чтение", systemImage: "checkmark.magnifyingglass") {
                        Task { await mailbox.checkReading() }
                    }.disabled(mailbox.expectedMailbox.isEmpty)
                    Button("Входящие", systemImage: "tray") { mailbox.openInbox() }
                    Button("Обновить", systemImage: "arrow.clockwise") { mailbox.refresh() }
                }
            }
            .padding()
            Text(addressError ?? mailbox.lastReadingCheck ?? mailbox.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 10)
            Divider()
            MailboxWebView(mailbox: mailbox)
        }
        .onAppear {
            address = mailbox.expectedMailbox
            mailbox.ensureLoaded()
        }
    }

    private func saveAddress() {
        do {
            try mailbox.setExpectedMailbox(address)
            address = mailbox.expectedMailbox
            addressError = nil
        } catch {
            addressError = "Введите корректный email ящика, открытого в Mail.ru."
        }
    }
}

struct MailboxWebView: NSViewRepresentable {
    let mailbox: MailRuMailbox

    func makeNSView(context: Context) -> WKWebView { mailbox.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
