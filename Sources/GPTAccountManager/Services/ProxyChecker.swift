import Foundation
import Network

enum ProxyChecker {
    static func check(_ proxy: AccountProxy) async -> ProxyCheckResult {
        await check(proxy) { url, configuration in
            try await download(url, configuration: configuration, limit: 4096, allowRedirects: false)
        }
    }

    static func check(
        _ proxy: AccountProxy,
        probe: @Sendable (URL, URLSessionConfiguration) async throws -> Data
    ) async -> ProxyCheckResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [proxy.nativeConfiguration()]
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        // A failed IP service does not prove that the proxy is down.
        let urls = [URL(string: "https://api.ipify.org?format=json")!,
                    URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!]
        for (index, url) in urls.enumerated() {
            let start = ContinuousClock.now
            do {
                try Task.checkCancellation()
                let data = try await probe(url, configuration)
                try Task.checkCancellation()
                guard data.count <= 4096 else { throw URLError(.dataLengthExceedsMaximum) }
                let ip: String
                if index == 0 {
                    struct IPResponse: Decodable { let ip: String }
                    ip = try JSONDecoder().decode(IPResponse.self, from: data).ip
                } else {
                    let values = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                        .filter { $0.hasPrefix("ip=") }
                    guard values.count == 1 else { throw URLError(.cannotParseResponse) }
                    ip = String(values[0].dropFirst(3))
                }
                guard IPv4Address(ip) != nil || IPv6Address(ip) != nil else { throw URLError(.cannotParseResponse) }
                let duration = start.duration(to: .now).components
                let milliseconds = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
                return .init(status: .available, latencyMilliseconds: milliseconds, exitIP: ip,
                             checkedAt: Date(), message: "Доступен: HTTPS через прокси")
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return .init(status: .unavailable, checkedAt: Date(), message: "Проверка отменена.")
                }
            }
        }
        return .init(status: .unavailable, checkedAt: Date(),
                     message: "Не удалось проверить HTTPS через прокси: оба проверочных сервиса не ответили корректно. Повторите проверку.")
    }

    static func fetchSource(_ url: URL) async throws -> String {
        guard validSourceURL(url) else { throw ProxyStoreError.invalidSource }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let data = try await download(url, configuration: configuration, limit: 1_048_576, allowRedirects: true)
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return text
    }

    static func validSourceURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    private static func download(
        _ url: URL, configuration: URLSessionConfiguration, limit: Int, allowRedirects: Bool
    ) async throws -> Data {
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(allowRedirects: allowRedirects), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: configuration.timeoutIntervalForRequest)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= limit else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        let allowRedirects: Bool
        init(allowRedirects: Bool) { self.allowRedirects = allowRedirects }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(allowRedirects && request.url.map(ProxyChecker.validSourceURL) == true ? request : nil)
        }
    }
}
