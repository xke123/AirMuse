import Foundation

// MARK: - LogSanitizer

/// Redacts sensitive credentials, tokens, cookies, JWTs, and personal secrets
/// before any log line is stored in memory, printed, or written to disk.
public enum LogSanitizer: Sendable {
    private static let patterns: [(NSRegularExpression, String)] = {
        let defs: [(String, String)] = [
            // Bearer tokens
            (#"(?i)(Bearer\s+)[A-Za-z0-9\-._~+/]+=*"#, "$1[REDACTED]"),
            // JWTs (header.payload.signature)
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "[REDACTED_JWT]"),
            // Media-User-Token header / cookie / query
            (#"(?i)(media-user-token\s*[:=]\s*\"?)[^;\s\"&]+"#, "$1[REDACTED]"),
            // Authorization / Cookie / Set-Cookie headers
            (#"(?i)((?:authorization|cookie|set-cookie|x-apple-music-user-token)\s*[:=]\s*)[^\r\n]+"#, "$1[REDACTED]"),
            // JSON secret fields
            (#"(?i)(\"(?:password|token|user_token|developer_token|media_user_token|secret|access_token|refresh_token)\"\s*:\s*\")[^\"]+\""#, "$1[REDACTED]\""),
        ]
        return defs.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    public static func redact(_ input: String) -> String {
        var result = input
        for (regex, replacement) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        return result
    }
}
