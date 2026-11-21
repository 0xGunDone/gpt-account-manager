import SwiftUI

struct OneTimeCodeView: View {
    let account: AccountRecord
    let onCopy: (String) -> Void

    var body: some View {
        TimelineView(PeriodicTimelineSchedule(from: Date.now, by: 1.0)) { context in
            content(at: context.date)
        }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        if let snapshot = OneTimeCodePresentation.snapshot(for: account, date: date) {
            Button {
                onCopy(snapshot.code)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.usesPendingSecret ? "Новый код" : "Код 2FA")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(formatted(snapshot.code))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .monospacedDigit()
                    }
                    Text("\(snapshot.secondsRemaining)с")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.quaternary))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            snapshot.usesPendingSecret
                                ? Color.orange
                                : Color.secondary.opacity(0.3),
                            lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .help("Скопировать одноразовый код")
            .accessibilityLabel("Скопировать код 2FA \(snapshot.code)")
        } else {
            Text("Код недоступен")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 38)
        }
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
