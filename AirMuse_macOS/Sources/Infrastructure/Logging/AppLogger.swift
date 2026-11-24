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
    case session    = "SESSION"
    case auth       = "AUTH"
    case engine     = "ENGINE"
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
    public let correlationID: String?
    public let message: String
    public let details: String?

    public init(
        level: LogLevel = .info,
        category: LogCategory,
        correlationID: String? = nil,
        message: String,
        details: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.correlationID = correlationID
        self.message = LogSanitizer.redact(message)
        self.details = details.map { LogSanitizer.redact($0) }
    }

    public var formattedTime: String {
        Self.formatTimestamp(timestamp)
    }

    public var formattedLine: String {
        let corr = correlationID.map { " [\($0)]" } ?? ""
        var line = "[\(formattedTime)] [\(level.rawValue)] [\(category.rawValue)]\(corr) \(message)"
        if let details = details, !details.isEmpty {
            line += "\n  ↳ \(details)"
        }
        return line
    }

    private static let timeLock = NSLock()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func formatTimestamp(_ date: Date) -> String {
        timeLock.lock()
        defer { timeLock.unlock() }
        return timeFormatter.string(from: date)
    }
}

// MARK: - AppLogger

/// Centralized Core V2 diagnostic logger for AirMuse macOS.
/// Automatically redacts sensitive credentials via `LogSanitizer` and rotates log files under a bounded size budget.
public final class AppLogger: @unchecked Sendable {

    public static let shared = AppLogger()

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let maxEntries: Int = 5000
    private let logDirectoryURL: URL
    private let maxFileBytes: Int
    private let maxRotatedFiles: Int

    public var onNewEntry: ((LogEntry) -> Void)?

    public init(
        logDirectoryURL: URL? = nil,
        maxFileBytes: Int = 2 * 1024 * 1024,
        maxRotatedFiles: Int = 2
    ) {
        if let customDir = logDirectoryURL {
            self.logDirectoryURL = customDir
        } else {
            let logsBase = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.logDirectoryURL = logsBase.appendingPathComponent("Logs/AirMuse", isDirectory: true)
        }
        self.maxFileBytes = max(1024, maxFileBytes)
        self.maxRotatedFiles = max(1, maxRotatedFiles)
        try? FileManager.default.createDirectory(at: self.logDirectoryURL, withIntermediateDirectories: true)

        log(
            category: .lifecycle,
            level: .info,
            message: "AppLogger (Core V2) initialized. System: macOS Darwin (arm64 Apple Silicon)",
            details: "LogFile: \(activeLogFileURL.path) | MaxBytes: \(self.maxFileBytes) | Rotated: \(self.maxRotatedFiles)"
        )
    }

    public var activeLogFileURL: URL {
        logDirectoryURL.appendingPathComponent("airmuse.log")
    }

    public func log(
        category: LogCategory,
        level: LogLevel = .info,
        correlationID: String? = nil,
        message: String,
        details: String? = nil
    ) {
        let entry = LogEntry(
            level: level,
            category: category,
            correlationID: correlationID,
            message: message,
            details: details
        )

        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        appendToRotatingLogFile(entry.formattedLine + "\n")
        let callback = onNewEntry
        lock.unlock()

        print(entry.formattedLine)

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
        AirMuse macOS Core V2 运行与诊断完整日志 (Diagnostics Report)
        生成时间: \(nowStr)
        运行架构: Apple Silicon (arm64) / Core V2 / AppKit Liquid Glass
        日志文件: \(activeLogFileURL.path)
        日志总数: \(copy.count) 条
        ======================================================================

        """

        for entry in copy {
            md += "\(entry.formattedLine)\n"
        }

        md += "\n======================== 日志输出结束 (EOF) ========================\n"
        return md
    }

    // MARK: - Bounded Log Rotation

    private func appendToRotatingLogFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fileURL = activeLogFileURL
        let fm = FileManager.default

        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue + data.count > maxFileBytes {
            rotateLogFiles()
        }

        if fm.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func rotateLogFiles() {
        let fm = FileManager.default
        let oldest = logDirectoryURL.appendingPathComponent("airmuse.log.\(maxRotatedFiles)")
        try? fm.removeItem(at: oldest)

        if maxRotatedFiles > 1 {
            for idx in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
                let src = logDirectoryURL.appendingPathComponent("airmuse.log.\(idx)")
                let dst = logDirectoryURL.appendingPathComponent("airmuse.log.\(idx + 1)")
                if fm.fileExists(atPath: src.path) {
                    try? fm.moveItem(at: src, to: dst)
                }
            }
        }

        let firstRotated = logDirectoryURL.appendingPathComponent("airmuse.log.1")
        if fm.fileExists(atPath: activeLogFileURL.path) {
            try? fm.moveItem(at: activeLogFileURL, to: firstRotated)
        }
    }
}
