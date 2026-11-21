import AppKit
import Foundation
import Network
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct AuthenticatedProxyTransportTests {
    @Test func urlSessionSendsConfiguredProxyCredentials() async throws {
        let server = try AuthenticationProxyFixture()
        defer { server.stop() }
        let proxy = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [proxy.nativeConfiguration()]
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        session.dataTask(with: AuthenticationProxyFixture.destination) { _, _, _ in }.resume()

        let authorized = try await server.waitForAuthorization()
        try #require(authorized, "URLSession must authenticate to the proxy")
        #expect(server.receivedCONNECT)
        #expect(server.credentialsMatched)
    }

    @Test func webViewSendsConfiguredProxyCredentials() async throws {
        _ = NSApplication.shared
        let server = try AuthenticationProxyFixture()
        defer { server.stop() }
        let proxy = try await server.start()
        let session = BrowserSession(dataStore: .nonPersistent(), proxy: proxy)
        defer { session.cancelLoading() }

        try #require(session.openAddress(AuthenticationProxyFixture.destination.absoluteString) != nil)

        let authorized = try await server.waitForAuthorization()
        try #require(authorized, "WKWebView must authenticate to the proxy")
        #expect(server.receivedCONNECT)
        #expect(server.credentialsMatched)
    }
}

/// Captures CONNECT authentication without opening a connection to the destination.
@MainActor
private final class AuthenticationProxyFixture {
    static let destination = URL(string: "https://192.0.2.1/")!
    private let username = "fixture-user"
    private let password = "fixture-password"
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var ready = false
    private var failed = false
    private var stopped = false
    private var receivedAuthorization = false
    private(set) var receivedCONNECT = false
    private(set) var credentialsMatched = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> AccountProxy {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.ready = true }
                if case .failed = state { self?.failed = true }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection)
            }
        }
        listener.start(queue: .main)
        let deadline = ContinuousClock.now + .seconds(3)
        while !ready && !failed && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready, "Loopback proxy must start before making requests")
        let port = try #require(listener.port)
        return AccountProxy(scheme: .http, host: "127.0.0.1", port: Int(port.rawValue),
                            username: username, password: password)
    }

    func waitForAuthorization() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        while !receivedAuthorization && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return receivedAuthorization
    }

    func stop() {
        stopped = true
        listener.cancel()
        connections.forEach { $0.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, !self.stopped else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count <= 16_384, error == nil else { connection.cancel(); return }
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if done { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                    return
                }
                let headers = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    .components(separatedBy: "\r\n")
                self.receivedCONNECT = headers.first?.hasPrefix("CONNECT 192.0.2.1:443 ") == true
                let authorization = headers.first { $0.lowercased().hasPrefix("proxy-authorization:") }
                if let authorization {
                    let value = authorization.dropFirst("proxy-authorization:".count)
                        .trimmingCharacters(in: .whitespaces)
                    let expected = "Basic " + Data("\(self.username):\(self.password)".utf8).base64EncodedString()
                    self.credentialsMatched = value == expected
                    self.receivedAuthorization = true
                    connection.cancel()
                } else {
                    let response = "HTTP/1.1 407 Proxy Authentication Required\r\n"
                        + "Proxy-Authenticate: Basic realm=\"fixture\"\r\n"
                        + "Content-Length: 0\r\nConnection: keep-alive\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
                        Task { @MainActor in
                            if error == nil { self?.receive(connection) } else { connection.cancel() }
                        }
                    })
                }
            }
        }
    }
}
