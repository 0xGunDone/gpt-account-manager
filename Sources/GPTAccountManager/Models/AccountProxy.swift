import Foundation
import Network

enum ProxyScheme: String, Codable, CaseIterable, Sendable {
    case http, https, socks5
}

struct AccountProxy: Codable, Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let scheme: ProxyScheme
    let host: String
    let port: Int
    let username: String?
    let password: String?

    var urlString: String {
        "\(scheme.rawValue)://\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }
    var displayName: String { urlString }
    var description: String { displayName }
    var debugDescription: String { displayName }

    var editableString: String {
        guard let username, let password else { return urlString }
        var parts = URLComponents(string: urlString)!
        parts.user = username
        parts.password = password
        return parts.string!
    }

    init(scheme: ProxyScheme, host: String, port: Int, username: String? = nil, password: String? = nil) {
        precondition(Self.validCredentials(username: username, password: password), "Invalid proxy credentials")
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    static func parse(_ text: String) throws -> AccountProxy {
        guard text.rangeOfCharacter(from: .controlCharacters) == nil else { throw ProxyStoreError.invalidProxy }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { throw ProxyStoreError.invalidProxy }
        let hasScheme = text.range(of: "://").map { !text[..<$0.lowerBound].contains(":") } ?? false
        let address = hasScheme ? text : "http://\(text)"
        let standardParts = URLComponents(string: address)
        let schemeEnd = address.range(of: "://")!.upperBound
        let authority = address[schemeEnd...]
        let hostEnd = authority.first == "[" ? authority.firstIndex(of: "]") : authority.firstIndex(of: ":")
        var endpoint = address
        var compactCredentials: (username: String, password: String)?
        if let hostEnd, standardParts?.user == nil || standardParts?.port == nil {
            let portStart = authority.first == "[" ? authority.index(after: hostEnd) : hostEnd
            if portStart < authority.endIndex, authority[portStart] == ":" {
                let fields = authority[authority.index(after: portStart)...]
                    .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if fields.count == 3, !fields[0].isEmpty, fields[0].utf8.allSatisfy({ (48...57).contains($0) }) {
                    endpoint = String(address[..<portStart]) + ":" + String(fields[0])
                    compactCredentials = (String(fields[1]), String(fields[2]))
                }
            }
        }
        guard let parts = URLComponents(string: endpoint),
              let scheme = ProxyScheme(rawValue: parts.scheme?.lowercased() ?? "")
        else { throw ProxyStoreError.invalidProxy }
        let username = compactCredentials?.username ?? parts.user
        let password = compactCredentials?.password ?? parts.password
        guard validCredentials(username: username, password: password),
              parts.percentEncodedUser == nil || parts.user != nil,
              parts.percentEncodedPassword == nil || parts.password != nil
        else { throw ProxyStoreError.invalidProxy }
        guard parts.query == nil, parts.fragment == nil, parts.path.isEmpty,
              let rawHost = parts.host, let port = parts.port, (1...65535).contains(port)
        else { throw ProxyStoreError.invalidProxy }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast()) : rawHost
        guard validHost(host) else { throw ProxyStoreError.invalidProxy }
        return AccountProxy(scheme: scheme, host: host.lowercased(), port: port, username: username, password: password)
    }

    private static func validCredentials(username: String?, password: String?) -> Bool {
        guard let username, let password else { return username == nil && password == nil }
        return !username.isEmpty && !password.isEmpty
            && username.rangeOfCharacter(from: .controlCharacters) == nil
            && password.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func validHost(_ host: String) -> Bool {
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return true }
        guard !host.isEmpty, host.utf8.count <= 253, !host.contains(":"),
              !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    private enum CodingKeys: String, CodingKey { case scheme, host, port, username, password }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let scheme = try values.decode(ProxyScheme.self, forKey: .scheme)
        let host = try values.decode(String.self, forKey: .host)
        let port = try values.decode(Int.self, forKey: .port)
        let username = try values.decodeIfPresent(String.self, forKey: .username)
        let password = try values.decodeIfPresent(String.self, forKey: .password)
        guard Self.validHost(host), (1...65535).contains(port), Self.validCredentials(username: username, password: password) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid proxy settings"))
        }
        self.init(scheme: scheme, host: host.lowercased(), port: port, username: username, password: password)
    }
}

struct ProxyEntry: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var proxy: AccountProxy
    var isEnabled = true
    var label = ""
    var check: ProxyCheckResult?
}

struct ProxyCheckResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case available, unavailable }
    var status: Status
    var latencyMilliseconds: Int?
    var exitIP: String?
    var checkedAt: Date
    var message: String
}

struct ProxySource: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var url: String
}

enum ProxyStoreError: Error, LocalizedError, Equatable {
    case invalidProxy, noValidProxies, duplicateProxy, missingProxy
    case invalidSource, duplicateSource, noSources, noAvailableProxy, insecurePermissions, unsupportedVersion
    case sourceDownload(String)

    var errorDescription: String? {
        switch self {
        case .invalidProxy: "Нужен адрес HTTP, HTTPS или SOCKS5: хост:порт или хост:порт:логин:пароль. Путь и параметры не поддерживаются."
        case .noValidProxies: "В списке нет корректных HTTP, HTTPS или SOCKS5 прокси. SOCKS4 не поддерживается."
        case .duplicateProxy: "Этот прокси уже есть в списке."
        case .missingProxy: "Прокси больше нет в списке."
        case .invalidSource: "Укажите HTTPS-ссылку на текстовый список без логина и пароля."
        case .duplicateSource: "Этот источник уже добавлен."
        case .noSources: "Добавьте источник списка прокси."
        case .noAvailableProxy: "Рабочий прокси не найден. Проверьте список или отключите прокси. Прямое подключение не выполнено."
        case .insecurePermissions: "Не удалось защитить файл настроек прокси."
        case .unsupportedVersion: "Версия файла настроек прокси не поддерживается."
        case .sourceDownload(let message): "Не удалось обновить источники: \(message)"
        }
    }
}
