import Network

extension AccountProxy {
    func nativeConfiguration() -> Network.ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: UInt16(port))!)
        var configuration: Network.ProxyConfiguration
        switch scheme {
        case .http:
            configuration = .init(httpCONNECTProxy: endpoint)
        case .https:
            configuration = .init(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        case .socks5:
            configuration = .init(socksv5Proxy: endpoint)
        }
        if let username, let password {
            configuration.applyCredential(username: username, password: password)
        }
        configuration.allowFailover = false
        configuration.matchDomains = []
        configuration.excludedDomains = []
        return configuration
    }
}
