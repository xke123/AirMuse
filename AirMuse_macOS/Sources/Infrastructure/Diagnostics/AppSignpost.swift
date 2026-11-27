import Domain
import Foundation
import OSLog

// MARK: - AppSignpost

/// Lightweight OSSignposter wrapper for Core V2 performance instrumentation.
/// Guarantees begin/end use the same OSSignpostID and provides a structured interval helper.
public final class AppSignpost: Sendable {
    public static let shared = AppSignpost()

    public struct IntervalHandle: @unchecked Sendable {
        fileprivate let state: OSSignpostIntervalState
    }

    private let signposter: OSSignposter

    public init(subsystem: String = "com.airmuse.macos", category: String = "CoreV2") {
        let log = OSLog(subsystem: subsystem, category: category)
        self.signposter = OSSignposter(logHandle: log)
    }

    public func beginInterval(_ name: StaticString) -> IntervalHandle {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        return IntervalHandle(state: state)
    }

    public func endInterval(_ name: StaticString, _ handle: IntervalHandle) {
        signposter.endInterval(name, handle.state)
    }

    public func emitEvent(_ name: StaticString) {
        let id = signposter.makeSignpostID()
        signposter.emitEvent(name, id: id)
    }

    public func withInterval<T>(
        _ name: StaticString,
        operation: () async throws -> T
    ) async rethrows -> T {
        let handle = beginInterval(name)
        defer { endInterval(name, handle) }
        return try await operation()
    }
}
