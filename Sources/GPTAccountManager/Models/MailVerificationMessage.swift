import Foundation

enum MailVerificationPurpose: Equatable, Sendable {
    case emailChange, registration, login, passwordChange
}

struct MailVerificationCode: Equatable, Sendable {
    let messageID: String
    let code: String
}

/// Values read from Mail.ru's rendered message headers, never from quoted body headers.
struct MailVerificationMessage: Equatable, Sendable {
    let messageID: String
    let sender: String
    let recipient: String
    let originalSender: String?
    let receivedAt: Date
    let subject: String
    let body: String
}

enum MailVerificationError: Error, LocalizedError, Equatable {
    case invalidAlias
    case signInRequired
    case unsupportedLayout
    case baselineRequired
    case ambiguousMessage
    case timedOut
    case cancelled
    case untrustedOrigin
    case unverifiedSender

    var errorDescription: String? {
        switch self {
        case .invalidAlias: "Некорректный адрес для получения кода."
        case .signInRequired: "Войдите в нужный ящик Mail.ru во вкладке «Почта»."
        case .unsupportedLayout:
            "Не удалось надёжно прочитать адрес ящика, список писем или заголовки Mail.ru. Откройте письмо и введите код вручную."
        case .baselineRequired: "Сначала откройте «Входящие» Mail.ru; проверка новых писем ещё не подготовлена."
        case .ambiguousMessage: "Найдено несколько подходящих кодов. Выберите актуальное письмо вручную."
        case .timedOut: "Новое письмо с подтверждённым адресатом и кодом не найдено за 120 секунд. Проверьте почту вручную."
        case .cancelled: "Проверка почты остановлена."
        case .untrustedOrigin: "Переход за пределы Mail.ru и страницы входа VK ID заблокирован."
        case .unverifiedSender: "Не удалось подтвердить отправителя и пересылку iCloud по заголовкам Mail.ru. Введите код вручную."
        }
    }
}

enum MailVerificationMatcher {
    static func sourceDate(rawHeaders: String) -> Date? {
        let headers = rawHeaders.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\n\n")[0]
            .replacingOccurrences(of: #"\r?\n[ \t]+"#, with: " ", options: .regularExpression)
        let dates = headers.components(separatedBy: .newlines).filter { $0.lowercased().hasPrefix("date:") }
        guard dates.count == 1 else { return nil }
        let value = dates[0].dropFirst(5).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+\([A-Za-z0-9 +:-]+\)$"#, with: "", options: .regularExpression)
        guard value.range(of: #"^[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: value)
    }

    static func verifiedOriginalSender(
        rawHeaders: String, visibleSender: String, visibleRecipient: String, expectedMailbox: String
    ) -> String? {
        guard rawHeaders.utf8.count <= 131_072, !rawHeaders.contains("\0"),
              sourceDate(rawHeaders: rawHeaders) != nil else { return nil }
        let raw = rawHeaders.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\n\n")[0]
        var headers: [String: [String]] = [:]
        var name: String?
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let name, let last = headers[name]?.indices.last else { return nil }
                headers[name]![last] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let key = String(line[..<separator]).lowercased()
            guard key.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
            headers[key, default: []].append(String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces))
            name = key
        }
        func single(_ name: String) -> String? {
            guard let values = headers[name], values.count == 1 else { return nil }
            return values[0]
        }
        func tags(_ value: String) -> [String: String]? {
            var result: [String: String] = [:]
            for part in value.split(separator: ";") {
                guard let separator = part.firstIndex(of: "=") else { return nil }
                let name = part[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard result[name] == nil else { return nil }
                result[name] = part[part.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return result
        }
        guard let sender = addressInHeader(visibleSender), let recipient = addressInHeader(visibleRecipient),
              let from = single("from").flatMap(addressInHeader), from == sender,
              let to = single("to").flatMap(addressInHeader), to == recipient,
              let authentication = single("authentication-results") else { return nil }
        let results = authentication.lowercased().components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard results.first == "mxs.mail.ru" else { return nil }
        func dkimPassed(_ domain: String) -> Bool {
            results.contains { result in
                let words = result.split(whereSeparator: \.isWhitespace)
                return words.first == "dkim=pass" && words.contains(Substring("header.d=\(domain)"))
            }
        }
        let domain = String(sender.split(separator: "@").last ?? "")
        if isOpenAIDomain(domain), dkimPassed(domain) {
            let signatures = (headers["dkim-signature"] ?? []).compactMap(tags).filter { $0["d"]?.lowercased() == domain }
            guard signatures.count == 1, signatures[0]["h"]?.lowercased().split(separator: ":").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("date") == true else { return nil }
            return sender
        }
        guard domain == "icloud.com", dkimPassed("icloud.com"),
              let hme = single("x-icloud-hme").flatMap(tags), hme["r"] == "to",
              hme["p"].flatMap(normalizedAddress) == recipient,
              hme["f"].flatMap(normalizedAddress) == normalizedAddress(expectedMailbox),
              let original = hme["s"].flatMap(normalizedAddress),
              let originalDomain = original.split(separator: "@").last.map(String.init),
              isOpenAIDomain(originalDomain) else { return nil }
        let signatures = (headers["dkim-signature"] ?? []).compactMap(tags).filter { $0["d"]?.lowercased() == "icloud.com" }
        guard signatures.count == 1, let signedNames = signatures[0]["h"]?.lowercased().split(separator: ":").map({ $0.trimmingCharacters(in: .whitespaces) }),
              ["from", "to", "date", "x-icloud-hme"].allSatisfy(signedNames.contains) else { return nil }
        return original
    }

    static func normalizedAddress(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: #"^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$"#,
                          options: .regularExpression) != nil else { return nil }
        return value
    }

    static func addressInHeader(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = normalizedAddress(value) { return direct }
        guard let open = value.firstIndex(of: "<"), value.last == ">",
              !value[..<open].contains("@"), !value[..<open].contains(">") else { return nil }
        return normalizedAddress(String(value[value.index(after: open)..<value.index(before: value.endIndex)]))
    }

    static func match(
        messages: [MailVerificationMessage], alias: String, since: Date,
        excluding: Set<String>, now: Date = Date(), purpose: MailVerificationPurpose = .emailChange
    ) throws -> MailVerificationCode? {
        guard let alias = normalizedAddress(alias) else { throw MailVerificationError.invalidAlias }
        var candidates: [MailVerificationCode] = []
        for message in messages {
            guard !message.messageID.isEmpty, !excluding.contains(message.messageID),
                  isFresh(message, since: since, now: now),
                  addressInHeader(message.recipient) == alias,
                  isOpenAISender(message), matchesPurpose(message, purpose: purpose)
            else { continue }
            let expression = try! NSRegularExpression(pattern: #"(?<![0-9])[0-9]{6}(?![0-9])"#)
            let text = message.subject + "\n" + message.body
            let codes = Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } })
            guard !codes.isEmpty else { continue }
            guard codes.count == 1, let code = codes.first else {
                throw MailVerificationError.ambiguousMessage
            }
            candidates.append(.init(messageID: message.messageID, code: code))
        }
        guard candidates.count <= 1 else { throw MailVerificationError.ambiguousMessage }
        return candidates.first
    }

    private static func isFresh(_ message: MailVerificationMessage, since: Date, now: Date) -> Bool {
        message.receivedAt >= since && message.receivedAt <= now
    }

    static func receivedDate(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        let pattern = #"^(?:[^,]+,\s*)?(\d{1,2})\s+(января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)\s+(\d{4}),?\s+(\d{1,2}):(\d{2})\s+([+-]\d{2}):(\d{2})$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let parts = (1...7).compactMap { Range(match.range(at: $0), in: value).map { String(value[$0]) } }
        let months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
        guard parts.count == 7, let day = Int(parts[0]), let month = months.firstIndex(of: parts[1].lowercased()),
              let year = Int(parts[2]), let hour = Int(parts[3]), let minute = Int(parts[4]),
              let zoneHour = Int(parts[5]), let zoneMinute = Int(parts[6]),
              (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute),
              abs(zoneHour) <= 14, (0...59).contains(zoneMinute) else { return nil }
        let offset = (abs(zoneHour) * 60 + zoneMinute) * 60 * (parts[5].hasPrefix("-") ? -1 : 1)
        guard let timeZone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard actual.year == year, actual.month == month + 1, actual.day == day,
              actual.hour == hour, actual.minute == minute else { return nil }
        return date
    }

    private static func isOpenAISender(_ message: MailVerificationMessage) -> Bool {
        guard let sender = addressInHeader(message.sender),
              let domain = sender.split(separator: "@").last.map(String.init) else { return false }
        if isOpenAIDomain(domain) { return true }
        // iCloud forwarding is accepted only with an original sender displayed
        // by the mailbox's header UI. A quoted "From:" in the body proves nothing.
        guard domain == "icloud.com" || domain.hasSuffix(".icloud.com"),
              let original = message.originalSender.flatMap(addressInHeader),
              let originalDomain = original.split(separator: "@").last.map(String.init) else { return false }
        return isOpenAIDomain(originalDomain)
    }

    private static func isOpenAIDomain(_ domain: String) -> Bool {
        domain == "openai.com" || domain.hasSuffix(".openai.com")
    }

    private static func isEmailChangeVerification(_ message: MailVerificationMessage) -> Bool {
        let text = (message.subject + "\n" + message.body).lowercased()
        let context = ["change your email", "change of email", "email address change", "email change",
                       "new email address", "смены почты", "смену почты", "смены адреса",
                       "изменение адреса", "изменить адрес электронной почты", "новый адрес электронной почты", "нового адреса электронной почты"]
        let verification = ["verification", "verify", "confirm", "подтвержд", "провероч"]
        return context.contains(where: text.contains) && verification.contains(where: text.contains)
    }

    private static func matchesPurpose(_ message: MailVerificationMessage, purpose: MailVerificationPurpose) -> Bool {
        if purpose == .emailChange { return isEmailChangeVerification(message) }
        let text = (message.subject + "\n" + message.body).lowercased()
        // Observed login template includes reset advice in its footer; that advice is not its purpose.
        let temporaryLoginSubject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == "your temporary chatgpt login code"
        if temporaryLoginSubject, !isEmailChangeVerification(message), text.contains("enter this code") {
            return true
        }
        if purpose == .passwordChange {
            guard !isEmailChangeVerification(message),
                  text.range(of: #"\b(?:chatgpt|openai)\b"#, options: .regularExpression) != nil else { return false }
            let verification = ["verification code", "verify your email", "verify your account", "confirm your email",
                                "one-time code", "one time code", "your chatgpt code", "your openai code",
                                "код подтверждения", "код проверки", "проверочный код", "временный код", "ваш код chatgpt"]
            return verification.contains(where: text.contains)
        }
        let otherPurpose = ["change your email", "change of email", "email address change", "email change",
                            "new email address", "смены почты", "смену почты", "смены адреса", "изменение адреса",
                            "изменить адрес электронной почты", "новый адрес электронной почты", "нового адреса электронной почты",
                            "reset your password", "password reset", "reset password", "сброс пароля", "сбросить пароль",
                            "восстановление пароля", "восстановить пароль"]
        guard !otherPurpose.contains(where: text.contains),
              text.range(of: #"\b(?:chatgpt|openai)\b"#, options: .regularExpression) != nil else { return false }
        let verification = ["verification code", "verify your email", "verify your account", "confirm your email",
                            "one-time code", "one time code", "your chatgpt code", "your openai code",
                            "код подтверждения", "код проверки", "проверочный код", "временный код", "ваш код chatgpt"]
        return verification.contains(where: text.contains)
    }
}
