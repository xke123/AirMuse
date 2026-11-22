import Foundation

// MARK: - LogLevel

public enum LogLevel: String, Sendable, CaseIterable {
    case info  = "INFO"
    case debug = "DEBUG"
    case warn  = "WARN"
    case error = "ERROR"
}

// MARK: - LogCategory

public enum LogCategory: String, Sendable, CaseIterable {
    case lifecycle  = "LIFECYCLE"
    case userAction = "USER_ACTION"
    case auth       = "AUTH"
    case injection  = "INJECTION"
    case ampAPI     = "AMP_API"
    case musicKit   = "MUSICKIT"
    case render     = "RENDER"
    case playback   = "PLAYBACK"
    case lyrics     = "LYRICS"
    case cache      = "CACHE"
    case database   = "DATABASE"
    case network    = "NETWORK"
    case error      = "ERROR"
}

// MARK: - LogEntry

public struct LogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let details: String?

    public init(
        level: LogLevel = .info,
        category: LogCategory,
        message: String,
        details: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
        self.details = details
    }

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    public var formattedLine: String {
        var line = "[\(formattedTime)] [\(level.rawValue)] [\(category.rawValue)] \(message)"
        if let details = details, !details.isEmpty {
            line += "\n  ↳ \(details)"
        }
        return line
    }
}

// MARK: - AppLogger

/// Centralized diagnostic logger for AirMuse macOS.
/// Records lifecycle, auth, injection, API network traffic, and UI rendering events.
public final class AppLogger: @unchecked Sendable {

    public static let shared = AppLogger()

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let maxEntries: Int = 5000

    public var onNewEntry: ((LogEntry) -> Void)?

    private init() {
        log(
            category: .lifecycle,
            level: .info,
            message: "AppLogger initialized. System: macOS Darwin (arm64 Apple Silicon)"
        )
    }

    public func log(
        category: LogCategory,
        level: LogLevel = .info,
        message: String,
        details: String? = nil
    ) {
        let entry = LogEntry(level: level, category: category, message: message, details: details)

        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        let callback = onNewEntry
        lock.unlock()

        // Mirror to stdout for command-line runs
        print(entry.formattedLine)

        // Also append to /tmp/airmuse.log for background diagnosis
        if let data = (entry.formattedLine + "\n").data(using: .utf8) {
            let logURL = URL(fileURLWithPath: "/tmp/airmuse.log")
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }

        if let callback = callback {
            DispatchQueue.main.async {
                callback(entry)
            }
        }
    }

    public func getEntries() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    public func exportMarkdown() -> String {
        lock.lock()
        let copy = entries
        lock.unlock()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let nowStr = df.string(from: Date())

        var md = """
        ======================================================================
        AirMuse macOS 运行与诊断完整日志 (Diagnostics Report)
        生成时间: \(nowStr)
        运行架构: Apple Silicon (arm64) / AppKit Liquid Glass
        日志总数: \(copy.count) 条
        ======================================================================

        """

        for entry in copy {
            md += "\(entry.formattedLine)\n"
        }

        md += "\n======================== 日志输出结束 (EOF) ========================\n"
        return md
    }
}
