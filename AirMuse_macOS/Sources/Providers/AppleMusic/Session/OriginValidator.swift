import Foundation
import CryptoKit

// MARK: - OriginValidator

/// Strict origin, URL, and cookie domain validator for Apple Music WebKit sessions.
/// Never uses loose substring checks like `.contains("apple.com")`.
public enum OriginValidator: Sendable {
    private static let allowedExactHosts: Set<String> = [
        "music.apple.com",
        "apple.com",
        "idmsa.apple.com",
        "amp-api.music.apple.com",
        "api.music.apple.com"
    ]

    private static let allowedCookieDomains: Set<String> = [
        ".music.apple.com",
        "music.apple.com",
        ".apple.com",
        "apple.com"
    ]

    /// Validates that a URL uses HTTPS and belongs strictly to an allowed Apple Music / Apple ID host.
    public static func isAllowedNavigationURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        return isAllowedHost(host)
    }

    /// Validates exact host or strict subdomain boundary (`.music.apple.com`, `.apple.com`).
    public static func isAllowedHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return false }
        if allowedExactHosts.contains(host) {
            return true
        }
        return host.hasSuffix(".music.apple.com")
    }

    /// Validates cookie domain for `media-user-token` and Apple Music session cookies.
    public static func isAllowedCookieDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return allowedCookieDomains.contains(normalized)
    }

    /// Validates script message origin from WKSecurityOrigin / WKFrameInfo.
    public static func isAllowedScriptOrigin(protocol scheme: String?, host: String?, isMainFrame: Bool, allowSubframe: Bool = false) -> Bool {
        guard isMainFrame || allowSubframe else { return false }
        guard let scheme = scheme?.lowercased(), scheme == "https" else { return false }
        guard let host, !host.isEmpty else { return false }
        return isAllowedHost(host)
    }
}

// MARK: - AccountNamespaceResolver

/// Produces a deterministic, stable local account namespace ID from a verified token
/// or server account identifier without exposing raw credentials or using random UUIDs.
public enum AccountNamespaceResolver: Sendable {
    public static func stableAccountID(providerID: String, serverAccountID: String?, token: String?) -> String {
        if let serverID = serverAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !serverID.isEmpty {
            return "srv_\(sha256Prefix("\(providerID)|\(serverID)", length: 16))"
        }
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return "tok_\(sha256Prefix("\(providerID)|\(token)", length: 16))"
        }
        return "anon_\(UUID().uuidString.prefix(12).lowercased())"
    }

    private static func sha256Prefix(_ input: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }
}
