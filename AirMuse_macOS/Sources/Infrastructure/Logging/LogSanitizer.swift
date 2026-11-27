import CryptoKit
import Domain
import Foundation

// MARK: - DiagnosticReferenceHasher

/// Produces stable, non-reversible HMAC-SHA256 references within a process run (or injected key).
/// The key is ephemeral in memory and never serialized or exported.
public final class DiagnosticReferenceHasher: Sendable {
    private let key: SymmetricKey

    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.key = key
    }

    public func reference(for rawValue: String, prefix: String = "ref") -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "absent" }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: key)
        let hex = mac.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)_\(hex)"
    }
}

// MARK: - LogSanitizer

/// Defense-in-depth sanitizer that redacts credentials, tokens, cookies, JWTs, OAuth parameters,
/// private file paths, URL query/fragment/userinfo, and log-injection newlines before any sink.
public enum LogSanitizer: Sendable {
    private static let maxFieldLength = 2048
    private static let maxFieldsCount = 64

    private static let patterns: [(NSRegularExpression, String)] = {
        let defs: [(String, String)] = [
            // Bearer tokens (raw and URL-encoded space)
            (#"(?i)(Bearer(?:\s+|%20))[A-Za-z0-9\-._~+/=%]+"#, "$1[REDACTED]"),
            // JWTs (header.payload.signature)
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "[REDACTED_JWT]"),
            // Media-User-Token header / cookie / query (including percent-encoded = %3D)
            (#"(?i)(media[-_]user[-_]token(?:\s*[:=]\s*|%3D)\"?)[A-Za-z0-9\-._~+/=%]+"#, "$1[REDACTED]"),
            // Authorization / Cookie / Set-Cookie / X-Apple-Music-User-Token headers
            (#"(?i)((?:authorization|cookie|set-cookie|x-apple-music-user-token|x-dsid|music-user-token)\s*[:=]\s*)[^\r\n]+"#, "$1[REDACTED]"),
            // JSON secret fields (normal and escaped quotes)
            (#"(?i)(\\?\"(?:password|token|user_token|developer_token|media_user_token|secret|access_token|refresh_token|client_secret|api_key|oauth_token|code_verifier|id_token|session_token|cookie)\\?\"\s*:\s*\\?\")[^\"\\]+(\\?\")"#, "$1[REDACTED]$2"),
            // Query / form / OAuth parameters (including percent-encoded & / =)
            (#"(?i)((?:[?&]|%26)(?:code|state|verifier|code_verifier|token|access_token|refresh_token|id_token|api_key|apikey|client_secret|password|auth|sig|signature|media-user-token)(?:=|%3D))[^&\s\r\n]+"#, "$1[REDACTED]"),
            // URL userinfo (scheme://user:pass@host)
            (#"(https?://)[^/@\s]+@"#, "$1[REDACTED]@"),
            // macOS user home path (/Users/<name>/...)
            (#"/Users/[^/\s]+(?:/[^\s]*)?"#, "/Users/[REDACTED]"),
        ]
        return defs.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    public static func redact(_ input: String) -> String {
        var result = input
        // Also decode percent-encoded secrets in a copy check if needed, then apply regexes
        for (regex, replacement) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        if result.count > maxFieldLength {
            let idx = result.index(result.startIndex, offsetBy: maxFieldLength)
            result = String(result[..<idx]) + "...[truncated]"
        }
        return result
    }

    /// Strips CR/LF and control characters for single-line identifiers (correlationID, eventName, etc.)
    public static func sanitizeSingleLine(_ input: String, maxLength: Int = 256) -> String {
        let stripped = input
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\0", with: "")
        let redacted = redact(stripped)
        if redacted.count > maxLength {
            let idx = redacted.index(redacted.startIndex, offsetBy: maxLength)
            return String(redacted[..<idx])
        }
        return redacted
    }

    public static func sanitizeURL(_ url: URL) -> (hostClass: String, endpointTemplate: String) {
        let host = url.host?.lowercased() ?? "unknown"
        let hostClass: String
        if host.contains("apple.com") || host.contains("mzstatic.com") {
            hostClass = "apple_service"
        } else if host == "localhost" || host == "127.0.0.1" {
            hostClass = "loopback"
        } else if host == "unknown" {
            hostClass = "unknown"
        } else {
            hostClass = "external_host"
        }

        let rawPath = url.path
        if rawPath.isEmpty {
            return (hostClass, "/")
        }
        let segments = rawPath.split(separator: "/").map { seg -> String in
            let s = String(seg)
            if s.allSatisfy({ $0.isNumber }) || s.count > 24 || s.contains(".") == false && s.rangeOfCharacter(from: .decimalDigits) != nil && s.count >= 8 {
                return "{id}"
            }
            return sanitizeSingleLine(s, maxLength: 48)
        }
        return (hostClass, "/" + segments.joined(separator: "/"))
    }

    public static func sanitizeContext(_ context: DiagnosticContext, hasher: DiagnosticReferenceHasher) -> DiagnosticContext {
        var copy = context
        copy.providerID = copy.providerID.map { sanitizeSingleLine($0, maxLength: 64) }
        copy.browsingProviderID = copy.browsingProviderID.map { sanitizeSingleLine($0, maxLength: 64) }
        copy.playingProviderID = copy.playingProviderID.map { sanitizeSingleLine($0, maxLength: 64) }
        copy.operationProviderID = copy.operationProviderID.map { sanitizeSingleLine($0, maxLength: 64) }
        copy.accountRef = copy.accountRef.map { sanitizeRefOrHash($0, prefix: "acct", hasher: hasher) }
        copy.storefront = copy.storefront.map { sanitizeSingleLine($0, maxLength: 32) }
        copy.leaseRef = copy.leaseRef.map { sanitizeSingleLine($0, maxLength: 64) }
        copy.switchRef = copy.switchRef.map { sanitizeSingleLine($0, maxLength: 64) }
        copy.stationRef = copy.stationRef.map { sanitizeRefOrHash($0, prefix: "stn", hasher: hasher) }
        copy.seedRef = copy.seedRef.map { sanitizeRefOrHash($0, prefix: "seed", hasher: hasher) }
        copy.currentItemRef = copy.currentItemRef.map { sanitizeRefOrHash($0, prefix: "item", hasher: hasher) }
        copy.resourceRef = copy.resourceRef.map { sanitizeRefOrHash($0, prefix: "res", hasher: hasher) }
        copy.resourceKind = copy.resourceKind.map { sanitizeSingleLine($0, maxLength: 32) }
        copy.scopeRef = copy.scopeRef.map { sanitizeRefOrHash($0, prefix: "scope", hasher: hasher) }
        copy.windowRef = copy.windowRef.map { sanitizeSingleLine($0, maxLength: 64) }
        copy.routeRef = copy.routeRef.map { sanitizeSingleLine($0, maxLength: 128) }
        copy.runtimeRef = copy.runtimeRef.map { sanitizeSingleLine($0, maxLength: 64) }
        return copy
    }

    private static func sanitizeRefOrHash(_ value: String, prefix: String, hasher: DiagnosticReferenceHasher) -> String {
        if value == "absent" || value.hasPrefix("\(prefix)_") || value.hasPrefix("ref_") {
            return sanitizeSingleLine(value, maxLength: 64)
        }
        return hasher.reference(for: value, prefix: prefix)
    }

    public static func sanitizeFields(_ fields: [String: DiagnosticFieldValue]) -> [String: DiagnosticFieldValue] {
        var sanitized: [String: DiagnosticFieldValue] = [:]
        var count = 0
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            guard count < maxFieldsCount else {
                sanitized["_truncatedFields"] = .bool(true)
                break
            }
            let safeKey = sanitizeSingleLine(key, maxLength: 64)
            switch value {
            case .string(let s):
                sanitized[safeKey] = .string(redact(s))
            case .strings(let arr):
                sanitized[safeKey] = .strings(arr.prefix(32).map { redact($0) })
            default:
                sanitized[safeKey] = value
            }
            count += 1
        }
        return sanitized
    }

    public static func sanitizeError(_ error: Error, stage: String? = nil) -> DiagnosticErrorInfo {
        if let coreError = error as? CoreError {
            return sanitizeCoreError(coreError, stage: stage)
        }
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            "\(sanitizeSingleLine($0.domain, maxLength: 64)):\($0.code)"
        }
        let retryable = (nsError.domain == NSURLErrorDomain && (
            nsError.code == NSURLErrorTimedOut ||
            nsError.code == NSURLErrorNetworkConnectionLost ||
            nsError.code == NSURLErrorNotConnectedToInternet
        ))
        return DiagnosticErrorInfo(
            domain: sanitizeSingleLine(nsError.domain, maxLength: 64),
            code: String(nsError.code),
            stage: stage.map { sanitizeSingleLine($0, maxLength: 64) },
            retryable: retryable,
            underlyingCode: underlying,
            safeSummary: redact(nsError.localizedDescription)
        )
    }

    private static func sanitizeCoreError(_ error: CoreError, stage: String?) -> DiagnosticErrorInfo {
        let code: String
        let retryable: Bool
        switch error {
        case .offline:
            code = "offline"; retryable = true
        case .timeout:
            code = "timeout"; retryable = true
        case .transport(let statusCode, _):
            code = statusCode.map { "transport_\($0)" } ?? "transport"; retryable = true
        case .clientCredentialInvalid:
            code = "clientCredentialInvalid"; retryable = false
        case .userCredentialInvalid:
            code = "userCredentialInvalid"; retryable = false
        case .forbidden:
            code = "forbidden"; retryable = false
        case .subscriptionRequired:
            code = "subscriptionRequired"; retryable = false
        case .rateLimited:
            code = "rateLimited"; retryable = true
        case .server(let statusCode, _):
            code = "server_\(statusCode)"; retryable = statusCode >= 500
        case .decode:
            code = "decode"; retryable = false
        case .notFound:
            code = "notFound"; retryable = false
        case .cancelled:
            code = "cancelled"; retryable = false
        case .staleSession:
            code = "staleSession"; retryable = false
        case .invalidCursor:
            code = "invalidCursor"; retryable = false
        case .superseded:
            code = "superseded"; retryable = false
        case .outcomeUnknown:
            code = "outcomeUnknown"; retryable = false
        case .engineUnavailable:
            code = "engineUnavailable"; retryable = false
        case .handoffFailed:
            code = "handoffFailed"; retryable = false
        case .permissionDenied:
            code = "permissionDenied"; retryable = false
        case .unsupported:
            code = "unsupported"; retryable = false
        case .storage:
            code = "storage"; retryable = false
        }
        return DiagnosticErrorInfo(
            domain: "AirMuse.CoreError",
            code: code,
            stage: stage.map { sanitizeSingleLine($0, maxLength: 64) },
            retryable: retryable,
            underlyingCode: nil,
            safeSummary: redact(error.localizedDescription)
        )
    }

    public static func sanitizeEvent(_ event: DiagnosticEvent, hasher: DiagnosticReferenceHasher) -> DiagnosticEvent {
        DiagnosticEvent(
            schemaVersion: event.schemaVersion,
            eventID: event.eventID,
            runID: event.runID,
            sequence: event.sequence,
            timestamp: event.timestamp,
            monotonicTimeNs: event.monotonicTimeNs,
            eventName: sanitizeSingleLine(event.eventName, maxLength: 96),
            category: sanitizeSingleLine(event.category, maxLength: 32),
            level: event.level,
            traceID: event.traceID,
            spanID: event.spanID,
            parentSpanID: event.parentSpanID,
            links: event.links,
            phase: event.phase,
            outcome: event.outcome,
            durationMs: event.durationMs,
            context: sanitizeContext(event.context, hasher: hasher),
            fields: sanitizeFields(event.fields),
            error: event.error.map {
                DiagnosticErrorInfo(
                    domain: sanitizeSingleLine($0.domain, maxLength: 64),
                    code: sanitizeSingleLine($0.code, maxLength: 64),
                    stage: $0.stage.map { sanitizeSingleLine($0, maxLength: 64) },
                    retryable: $0.retryable,
                    underlyingCode: $0.underlyingCode.map { sanitizeSingleLine($0, maxLength: 64) },
                    safeSummary: redact($0.safeSummary)
                )
            },
            source: DiagnosticSourceLocation(
                module: sanitizeSingleLine(event.source.module, maxLength: 64),
                component: sanitizeSingleLine(event.source.component, maxLength: 64),
                function: sanitizeSingleLine(event.source.function, maxLength: 128),
                fileID: event.source.fileID.map { sanitizeSingleLine($0, maxLength: 128) },
                line: event.source.line
            ),
            message: redact(event.message)
        )
    }
}
