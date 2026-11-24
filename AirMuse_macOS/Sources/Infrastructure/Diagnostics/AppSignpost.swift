import Foundation
import OSLog

// MARK: - AppSignpost

/// Lightweight OSSignposter wrapper for Core V2 performance instrumentation.
/// Covers startup, cache, session, engine, and first-play latency measurement.
public final class AppSignpost: Sendable {
    public static let shared = AppSignpost()

    private let signposter: OSSignposter

    public init(subsystem: String = "com.airmuse.macos", category: String = "CoreV2") {
        let log = OSLog(subsystem: subsystem, category: category)
        self.signposter = OSSignposter(logHandle: log)
    }

    public func beginInterval(_ name: StaticString) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        return signposter.beginInterval(name, id: id)
    }

    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    public func emitEvent(_ name: StaticString) {
        let id = signposter.makeSignpostID()
        signposter.emitEvent(name, id: id)
    }
}
