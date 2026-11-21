import CoreImage
import Foundation
import Vision
import WebKit

enum QRCodeSecretError: Error {
    case missingURI
    case ambiguousURI
    case invalidURI
    case invalidSecret
}

enum QRCodeSecretExtractor {
    static func secret(from uri: String) throws -> String {
        guard let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "otpauth",
              components.host?.lowercased() == "totp"
        else { throw QRCodeSecretError.invalidURI }
        guard let raw = components.queryItems?.first(where: {
            $0.name.caseInsensitiveCompare("secret") == .orderedSame
        })?.value else {
            throw QRCodeSecretError.missingURI
        }
        let normalized = TOTPService.normalizedSecret(raw)
        guard TOTPService.isValidSecret(normalized) else {
            throw QRCodeSecretError.invalidSecret
        }
        return normalized
    }

    static func uniqueSecret(
        from uris: [String],
        plainSecrets: [String] = []
    ) throws -> String {
        let candidates = uris.filter {
            $0.lowercased().starts(with: "otpauth://")
        }
        var secrets = try Set(candidates.map(secret(from:)))
        for raw in plainSecrets {
            let normalized = TOTPService.normalizedSecret(raw)
            if TOTPService.isValidSecret(normalized) {
                secrets.insert(normalized)
            }
        }
        guard !secrets.isEmpty else { throw QRCodeSecretError.missingURI }
        guard secrets.count == 1, let secret = secrets.first else {
            throw QRCodeSecretError.ambiguousURI
        }
        return secret
    }

    @MainActor
    static func extract(from webView: WKWebView, textOnly: Bool = false) async throws -> String {
        let script = #"""
        (() => {
          const candidates = [];
          for (const element of document.querySelectorAll("a[href], img[src], [data-uri]")) {
            candidates.push(element.href || element.src || element.dataset.uri || "");
          }
          const textMatches = (document.body?.innerText || "")
            .match(/otpauth:\/\/[^\s]+/gi) || [];
          candidates.push(...textMatches);
          const setupLabels = new Set([
            "connect your authenticator app",
            "подключите приложение для аутентификации",
            "добавьте свою учетную запись в приложение",
          ]);
          const normalize = value => String(value || "")
            .replace(/\s+/g, " ").trim().toLowerCase();
          const displayed = element => {
            for (let current = element; current; current = current.parentElement) {
              const style = getComputedStyle(current);
              if (current.hidden || current.getAttribute("aria-hidden") === "true" ||
                  style.visibility === "hidden" || style.display === "none") return false;
            }
            const rect = element.getBoundingClientRect();
            return rect.width > 0 || rect.height > 0;
          };
          const setupHeadings = [...document.querySelectorAll("h1, h2, h3, h4")]
            .filter(displayed)
            .filter(element => setupLabels.has(normalize(element.innerText)));
          const setupRoots = [...new Set(setupHeadings.map(element =>
            element.closest("[role='dialog'], [data-state='open']") ||
              element.parentElement?.parentElement).filter(Boolean))];
          const plainSecrets = setupRoots.length === 1
            ? (setupRoots[0].innerText || "").match(/\b[A-Z2-7]{16,64}\b/gi) || []
            : [];
          return {
            uris: [...new Set(candidates.filter(value =>
              String(value).toLowerCase().startsWith("otpauth://")))],
            plainSecrets: [...new Set(plainSecrets)],
          };
        })()
        """#
        let payload = try await webView.evaluateJavaScript(script) as? [String: Any]
        var uris = payload?["uris"] as? [String] ?? []
        let plainSecrets = payload?["plainSecrets"] as? [String] ?? []
        if textOnly { return try uniqueSecret(from: [], plainSecrets: plainSecrets) }

        let image = try await webView.takeSnapshot(configuration: nil)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return try uniqueSecret(from: uris, plainSecrets: plainSecrets)
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        uris.append(contentsOf: request.results?.compactMap(\.payloadStringValue) ?? [])
        return try uniqueSecret(from: uris, plainSecrets: plainSecrets)
    }
}
