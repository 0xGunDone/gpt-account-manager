import Foundation

enum AccountTokenExportFormat: String, CaseIterable, Identifiable, Sendable {
    case text, cpa, sub2api, cockpit

    var id: Self { self }
    var title: String {
        switch self {
        case .text: "Текст · EMAIL|AT"
        case .cpa: "CPA JSON"
        case .sub2api: "sub2api JSON"
        case .cockpit: "Cockpit JSON"
        }
    }
    var fileExtension: String { self == .text ? "txt" : "json" }
}

struct AccountTokenExportResult: Sendable {
    let data: Data
    let documents: [Data]
    let exportedCount: Int
    let skippedCount: Int
    let expiredCount: Int
    let warning: String?
}

enum AccountTokenExport {
    static func make(
        accounts: [AccountRecord], format: AccountTokenExportFormat, now: Date = Date()
    ) throws -> AccountTokenExportResult {
        var seenIDs: Set<UUID> = []
        var lines: [String] = []
        var rows: [[String: Any]] = []
        var expiredCount = 0
        var missingIDCount = 0
        var unknownExpiryCount = 0
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for account in accounts {
            guard seenIDs.insert(account.id).inserted, isEligible(account),
                  let token = account.accessToken, let line = account.accessTokenLine else { continue }
            let metadata = AccessTokenMetadata(token: token)
            let expired = metadata.validity(at: now) == .expired
            guard metadata.emailClaims.allSatisfy({
                AccessTokenExport.isValidField($0) && $0.caseInsensitiveCompare(account.email) == .orderedSame
            }) else { continue }
            if expired { expiredCount += 1 }
            if format == .text {
                lines.append(line)
                if metadata.expiresAt == nil { unknownExpiryCount += 1 }
                continue
            }
            guard !expired else { continue }
            guard let accountID = metadata.accountID, AccessTokenExport.isValidField(accountID) else {
                missingIDCount += 1
                continue
            }
            guard [metadata.userID, metadata.plan].allSatisfy({ value in
                value.map(AccessTokenExport.isValidField) ?? true
            }) else { continue }

            let expiry = metadata.expiresAt.map { formatter.string(from: $0) }
            var row: [String: Any]
            switch format {
            case .text:
                continue
            case .cpa, .cockpit:
                row = ["type": "codex", "email": account.email, "account_id": accountID, "access_token": token]
                if let expiry { row["expired"] = expiry }
                if format == .cpa {
                    row["chatgpt_account_id"] = accountID
                    row["name"] = account.email
                    if let plan = metadata.plan {
                        row["plan_type"] = plan
                        row["chatgpt_plan_type"] = plan
                    }
                }
            case .sub2api:
                var credentials: [String: Any] = [
                    "access_token": token, "chatgpt_account_id": accountID, "email": account.email,
                ]
                if let userID = metadata.userID { credentials["chatgpt_user_id"] = userID }
                if let plan = metadata.plan { credentials["plan_type"] = plan }
                if let expiry { credentials["expires_at"] = expiry }
                row = ["name": account.email, "platform": "openai", "type": "oauth", "credentials": credentials]
                if let expiresAt = metadata.expiresAt {
                    row["expires_at"] = expiresAt.timeIntervalSince1970
                    row["auto_pause_on_expired"] = true
                }
            }
            rows.append(row)
            if metadata.expiresAt == nil { unknownExpiryCount += 1 }
        }

        let exportedCount = format == .text ? lines.count : rows.count
        let skippedCount = accounts.count - exportedCount
        let data: Data
        let documents: [Data]
        if format == .text {
            data = Data(lines.joined(separator: "\n").utf8)
            documents = []
        } else if format == .cpa {
            documents = try rows.map {
                try JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys])
            }
            data = documents.count == 1 ? documents[0] : Data()
        } else {
            let object: Any = format == .sub2api
                ? ["exported_at": formatter.string(from: now), "proxies": [], "accounts": rows] as [String: Any]
                : rows
            data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            documents = []
        }
        var warnings: [String] = []
        if format != .text {
            warnings.append("Экспорт содержит только access token. Автоматическое OAuth-обновление невозможно без refresh token.")
        }
        if expiredCount > 0 {
            warnings.append(format == .text
                ? "Истёкших токенов в тексте: \(expiredCount)."
                : "Истёкших токенов пропущено: \(expiredCount).")
        }
        if unknownExpiryCount > 0 { warnings.append("Срок действия неизвестен у токенов: \(unknownExpiryCount).") }
        if missingIDCount > 0 { warnings.append("Без корректного внешнего account_id пропущено: \(missingIDCount).") }
        if skippedCount > 0 { warnings.append("Всего пропущено записей: \(skippedCount).") }
        return AccountTokenExportResult(
            data: data, documents: documents, exportedCount: exportedCount, skippedCount: skippedCount,
            expiredCount: expiredCount, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    private static func isEligible(_ account: AccountRecord) -> Bool {
        account.status == .ready && !account.hasPendingCredentialChange &&
            account.rotationStage == nil && account.pendingTOTPSecret == nil
    }
}
