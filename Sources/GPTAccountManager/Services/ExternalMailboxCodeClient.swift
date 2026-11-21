import CryptoKit
import Foundation

struct ExternalMailboxConfiguration: Codable, Equatable, Sendable {
    let address: String
    let codeURL: URL

    init(address: String, codeURL: String) throws {
        guard let address = MailVerificationMatcher.normalizedAddress(address) else {
            throw ExternalMailboxError.invalidAddress
        }
        guard let url = URL(string: codeURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              Self.isCodeURL(url) else { throw ExternalMailboxError.invalidURL }
        self.address = address
        self.codeURL = url
    }

    static func isCodeURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
            url.host?.isEmpty == false && url.user == nil && url.password == nil &&
            url.fragment == nil
    }
}

enum ExternalMailboxError: LocalizedError, Equatable {
    case invalidAddress, invalidURL, unavailable, temporary, unsupportedResponse, timedOut

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Укажите действительный адрес почтового ящика."
        case .invalidURL: "Укажите HTTPS-ссылку API получения кода без логина и пароля в адресе."
        case .unavailable: "API почты недоступен или отклонил запрос. Введите код вручную."
        case .temporary: "API почты временно недоступен. Введите код вручную."
        case .unsupportedResponse: "API почты вернул неизвестный ответ. Введите код вручную."
        case .timedOut: "В API почты не появился новый код. Введите код вручную."
        }
    }
}

@MainActor
final class ExternalMailboxCodeClient: EmailCodeReceiving {
    typealias Load = (URL) async throws -> Data
    private static let emptyMarker = "external-mailbox:none"
    private static let codeMarkerPrefix = "external-mailbox:code:"
    private static let waitSeconds: TimeInterval = 120
    private let configuration: ExternalMailboxConfiguration
    private let load: Load
    private let pollInterval: Duration
    private var generation = 0

    init(configuration: ExternalMailboxConfiguration,
         load: Load? = nil, pollInterval: Duration = .seconds(3)) {
        self.configuration = configuration
        self.load = load ?? Self.readEndpoint
        self.pollInterval = pollInterval
    }

    static func baselineHasCode(_ baseline: Set<String>) -> Bool {
        baseline.contains { $0.hasPrefix(codeMarkerPrefix) }
    }

    func captureBaseline() async throws -> Set<String> {
        let code = try await readCode(generation: generation)
        return [code.map(Self.marker) ?? Self.emptyMarker]
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        try await waitForCode(alias: alias, since: since, excluding: excluding, purpose: .login)
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>,
                     purpose: MailVerificationPurpose) async throws -> MailVerificationCode {
        guard purpose == .login else { throw ExternalMailboxError.unsupportedResponse }
        guard MailVerificationMatcher.normalizedAddress(alias) != nil else {
            throw MailVerificationError.invalidAlias
        }
        guard excluding.count == 1,
              excluding.contains(Self.emptyMarker) || Self.baselineHasCode(excluding) else {
            throw MailVerificationError.baselineRequired
        }
        let elapsed = Date().timeIntervalSince(since)
        guard elapsed >= 0, elapsed < Self.waitSeconds else { throw ExternalMailboxError.timedOut }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(Self.waitSeconds - elapsed)
        let generation = self.generation
        while clock.now < deadline {
            do {
                if let code = try await readCode(generation: generation), clock.now < deadline {
                    let id = Self.marker(code)
                    if !excluding.contains(id) { return .init(messageID: id, code: code) }
                }
            } catch ExternalMailboxError.temporary {
                // Retry only the mailbox read. The login request is already in flight.
            }
            try await clock.sleep(until: min(deadline, clock.now + pollInterval))
            try checkCancellation(generation)
        }
        throw ExternalMailboxError.timedOut
    }

    func cancel() { generation += 1 }

    private func checkCancellation(_ generation: Int) throws {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
    }

    private func readCode(generation: Int) async throws -> String? {
        try checkCancellation(generation)
        guard ExternalMailboxConfiguration.isCodeURL(configuration.codeURL),
              MailVerificationMatcher.normalizedAddress(configuration.address) == configuration.address else {
            throw ExternalMailboxError.invalidURL
        }
        let data: Data
        do { data = try await load(configuration.codeURL) }
        catch {
            try checkCancellation(generation)
            throw (error as? ExternalMailboxError) ?? .unavailable
        }
        try checkCancellation(generation)
        return try Self.decodeCode(data)
    }

    static func decodeCode(_ data: Data) throws -> String? {
        struct Reply: Decodable { let success: Bool; let code: String }
        guard data.count <= 16_384, let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw ExternalMailboxError.unsupportedResponse
        }
        if !reply.success {
            if reply.code == "no_code" { return nil }
            throw ExternalMailboxError.unavailable
        }
        guard reply.code.utf8.count == 6,
              reply.code.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            throw ExternalMailboxError.unsupportedResponse
        }
        return reply.code
    }

    private static func marker(_ code: String) -> String {
        codeMarkerPrefix + SHA256.hash(data: Data(code.utf8)).description
    }

    private static let session: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.urlCache = nil
        settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 8
        settings.timeoutIntervalForResource = 12
        return URLSession(configuration: settings, delegate: ExternalMailboxNoRedirects(), delegateQueue: nil)
    }()

    private static func readEndpoint(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch {
            try Task.checkCancellation()
            throw ExternalMailboxError.temporary
        }
        guard let http = response as? HTTPURLResponse, http.url == url else {
            bytes.task.cancel()
            throw ExternalMailboxError.unavailable
        }
        guard http.statusCode == 200 else {
            bytes.task.cancel()
            if http.statusCode == 429 || (500 ... 599).contains(http.statusCode) {
                throw ExternalMailboxError.temporary
            }
            throw ExternalMailboxError.unavailable
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16_384 else {
                bytes.task.cancel()
                throw ExternalMailboxError.unsupportedResponse
            }
            data.append(byte)
        }
        return data
    }
}

private final class ExternalMailboxNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
