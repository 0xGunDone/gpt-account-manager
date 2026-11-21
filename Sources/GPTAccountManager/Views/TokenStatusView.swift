import SwiftUI

struct TokenStatusView: View {
    let token: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let metadata = AccessTokenMetadata(token: token)
            let validity = metadata.validity(at: context.date)
            HStack(spacing: 5) {
                Image(systemName: "key.horizontal")
                Text(label(validity))
                if let expiry = metadata.expiresAt {
                    Text(expiry, format: .dateTime.day().month().hour().minute())
                }
            }
            .font(.caption)
            .foregroundStyle(validity == .expired ? Color.red : validity == .expiringSoon ? .orange : .secondary)
            .help("Срок прочитан из метаданных токена. Это не проверка подписи или доступности аккаунта.")
        }
    }

    private func label(_ validity: TokenValidity) -> String {
        switch validity {
        case .missing: "accessToken не сохранён"
        case .unknown: "Срок accessToken неизвестен"
        case .expired: "accessToken истёк:"
        case .expiringSoon: "accessToken скоро истечёт:"
        case .valid: "accessToken действует до:"
        }
    }
}
