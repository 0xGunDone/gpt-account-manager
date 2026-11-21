import AppKit
import Darwin
import Foundation

struct CodexAccImportAttempt: Equatable, Sendable {
    let id: String
    let authorizationURL: URL
    let expiresInSeconds: TimeInterval
}

enum CodexAccImportStart: Equatable, Sendable {
    case pending(CodexAccImportAttempt)
    case complete(email: String, accountID: String)
}

enum CodexAccImportStatus: Equatable, Sendable {
    case pending
    case complete(email: String, accountID: String)
    case failed
    case cancelled
}

enum CodexAccImportError: Error, LocalizedError, Equatable {
    case unavailable, invalidDescriptor, invalidResponse, requestFailed, wrongAccount

    var errorDescription: String? {
        switch self {
        case .unavailable: "Не удалось подключиться к CodexAcc. Откройте обновлённую версию CodexAcc и повторите импорт."
        case .invalidDescriptor: "Параметры локального подключения CodexAcc не прошли проверку безопасности."
        case .invalidResponse: "CodexAcc вернул неподходящий ответ. Импорт приостановлен."
        case .requestFailed: "Связь с CodexAcc прервана. Импорт приостановлен."
        case .wrongAccount: "CodexAcc подтвердил другой аккаунт. Импорт приостановлен."
        }
    }
}

struct CodexAccBridgeDescriptor: Decodable, Equatable, Sendable {
    let port: Int
    let token: String

    private func validate() throws {
        guard (1...65535).contains(port), (32...512).contains(token.utf8.count),
              token.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
        else { throw CodexAccImportError.invalidDescriptor }
    }

    static func read(from url: URL) throws -> Self? {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else {
            if errno == ENOENT { return nil }
            throw CodexAccImportError.invalidDescriptor
        }
        defer { close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == getuid(),
              parentInfo.st_mode & S_IFMT == S_IFDIR, parentInfo.st_mode & 0o7777 == 0o700
        else { throw CodexAccImportError.invalidDescriptor }
        let file = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw CodexAccImportError.invalidDescriptor
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600,
              info.st_size > 0, info.st_size <= 4096
        else { throw CodexAccImportError.invalidDescriptor }
        do {
            let data = try handle.read(upToCount: 4097) ?? Data()
            guard !data.isEmpty, data.count <= 4096 else { throw CodexAccImportError.invalidDescriptor }
            let descriptor = try JSONDecoder().decode(Self.self, from: data)
            try descriptor.validate()
            return descriptor
        } catch {
            throw CodexAccImportError.invalidDescriptor
        }
    }
}

private final class CodexAccNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
final class CodexAccImportClient {
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    private struct Reply: Decodable {
        let status: String
        let attempt_id: String?
        let auth_url: String?
        let expires_in_seconds: Double?
        let email: String?
        let account_id: String?
    }

    static var descriptorURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexAcc/import-bridge.json")
    }

    private let readDescriptor: @MainActor () throws -> CodexAccBridgeDescriptor?
    private let launch: @MainActor () async throws -> Void
    private let transport: Transport
    private let wait: @MainActor () async throws -> Void
    private var connections: [String: CodexAccBridgeDescriptor] = [:]
    private var restartedAttempts: Set<String> = []

    init(
        readDescriptor: @escaping @MainActor () throws -> CodexAccBridgeDescriptor? = {
            try CodexAccBridgeDescriptor.read(from: CodexAccImportClient.descriptorURL)
        },
        launch: @escaping @MainActor () async throws -> Void = {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/CodexAcc.app"), configuration: configuration)
        },
        transport: Transport? = nil,
        wait: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }
    ) {
        self.readDescriptor = readDescriptor
        self.launch = launch
        self.wait = wait
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 12
            let session = URLSession(configuration: configuration, delegate: CodexAccNoRedirects(), delegateQueue: nil)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw CodexAccImportError.invalidResponse }
                return (data, response)
            }
        }
    }

    func start(account: AccountRecord) async throws -> CodexAccImportStart {
        var descriptor = try await connection()
        let body = ["email": account.email, "name": account.tag ?? account.email]
        let reply: Reply
        do {
            reply = try await request("start", body: body, descriptor: descriptor)
        } catch CodexAccImportError.unavailable {
            // Only a refused connection is safe to retry; an interrupted response may already have created an attempt.
            descriptor = try await launchedConnection(replacing: descriptor)
            reply = try await request("start", body: body, descriptor: descriptor)
        }
        if reply.status == "complete" {
            let identity = try identity(reply)
            return .complete(email: identity.email, accountID: identity.accountID)
        }
        guard reply.status == "pending", let id = reply.attempt_id, validIdentifier(id),
              let rawURL = reply.auth_url, rawURL.utf8.count <= 8192, let url = URL(string: rawURL),
              let expiry = reply.expires_in_seconds, expiry.isFinite, expiry > 0, expiry <= 300
        else { throw CodexAccImportError.invalidResponse }
        // Keep the same connection for this attempt even if CodexAcc replaces its descriptor.
        connections[id] = descriptor
        return .pending(.init(id: id, authorizationURL: url, expiresInSeconds: expiry))
    }

    func status(attemptID: String) async throws -> CodexAccImportStatus {
        try await update("status", attemptID: attemptID)
    }

    func cancel(attemptID: String) async throws -> CodexAccImportStatus {
        let result = try await update("cancel", attemptID: attemptID)
        guard result != .pending else { throw CodexAccImportError.invalidResponse }
        // Keep the descriptor for idempotent cancellation if a caller rejects the returned identity.
        return result
    }

    private func connection() async throws -> CodexAccBridgeDescriptor {
        if let descriptor = try readDescriptor() { return descriptor }
        return try await launchedConnection(replacing: nil)
    }

    private func launchedConnection(replacing previous: CodexAccBridgeDescriptor?) async throws -> CodexAccBridgeDescriptor {
        do { try await launch() } catch { throw CodexAccImportError.unavailable }
        for _ in 0..<40 {
            try Task.checkCancellation()
            if let descriptor = try readDescriptor(), descriptor != previous { return descriptor }
            try await wait()
        }
        throw CodexAccImportError.unavailable
    }

    private func update(_ action: String, attemptID: String) async throws -> CodexAccImportStatus {
        guard let descriptor = connections[attemptID] else { throw CodexAccImportError.invalidResponse }
        let reply: Reply
        do {
            reply = try await request(action, body: ["attempt_id": attemptID], descriptor: descriptor,
                                      allowMissingAttempt: restartedAttempts.contains(attemptID))
        } catch let error as CodexAccImportError where error == .unavailable || error == .invalidResponse {
            guard let replacement = try readDescriptor(), replacement != descriptor else {
                throw error
            }
            // A restarted bridge can confirm that its predecessor's attempt no longer exists.
            reply = try await request(action, body: ["attempt_id": attemptID], descriptor: replacement, allowMissingAttempt: true)
            connections[attemptID] = replacement
            restartedAttempts.insert(attemptID)
        }
        switch reply.status {
        case "pending":
            guard reply.attempt_id == attemptID else { throw CodexAccImportError.invalidResponse }
            return .pending
        case "complete":
            let identity = try identity(reply)
            return .complete(email: identity.email, accountID: identity.accountID)
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: throw CodexAccImportError.invalidResponse
        }
    }

    private func request(_ action: String, body: [String: String], descriptor: CodexAccBridgeDescriptor, allowMissingAttempt: Bool = false) async throws -> Reply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(descriptor.port)/import/\(action)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await transport(request)
            if allowMissingAttempt, response.statusCode == 404, response.url == request.url {
                return Reply(status: action == "cancel" ? "cancelled" : "failed", attempt_id: nil,
                             auth_url: nil, expires_in_seconds: nil, email: nil, account_id: nil)
            }
            guard (200...299).contains(response.statusCode), response.url == request.url,
                  data.count <= 16_384 else { throw CodexAccImportError.invalidResponse }
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexAccImportError {
            throw error
        } catch {
            if (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == NSURLErrorCannotConnectToHost {
                throw CodexAccImportError.unavailable
            }
            // Network errors may contain authorization URLs or request headers.
            throw CodexAccImportError.requestFailed
        }
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
    }

    private func identity(_ reply: Reply) throws -> (email: String, accountID: String) {
        guard let email = reply.email, !email.isEmpty, email.utf8.count <= 320,
              let accountID = reply.account_id, validIdentifier(accountID)
        else { throw CodexAccImportError.invalidResponse }
        return (email, accountID)
    }
}
