import CryptoKit
import Domain
import Foundation

// MARK: - AppEnvironmentInfo

public struct AppEnvironmentInfo: Sendable, Codable, Equatable {
    public let appVersion: String
    public let buildNumber: String
    public let commit: String
    public let osVersion: String
    public let arch: String
    public let sdk: String
    public let processName: String
    public let isFixtureHost: Bool

    public init(
        appVersion: String,
        buildNumber: String,
        commit: String,
        osVersion: String,
        arch: String,
        sdk: String,
        processName: String,
        isFixtureHost: Bool
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.commit = commit
        self.osVersion = osVersion
        self.arch = arch
        self.sdk = sdk
        self.processName = processName
        self.isFixtureHost = isFixtureHost
    }

    public static func current() -> AppEnvironmentInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let appVersion = (info["CFBundleShortVersionString"] as? String).nonEmptyOrUnknown
        let buildNumber = (info["CFBundleVersion"] as? String).nonEmptyOrUnknown
        let commit = (info["AirMuseGitCommit"] as? String ?? env["AIRMUSE_GIT_COMMIT"]).nonEmptyOrUnknown
        let sdk = (info["DTSDKName"] as? String).nonEmptyOrUnknown
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let processName = ProcessInfo.processInfo.processName

        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif

        return AppEnvironmentInfo(
            appVersion: appVersion,
            buildNumber: buildNumber,
            commit: commit,
            osVersion: osVersion,
            arch: arch,
            sdk: sdk,
            processName: processName,
            isFixtureHost: processName.localizedCaseInsensitiveContains("FixtureHost")
        )
    }
}

private extension Optional where Wrapped == String {
    var nonEmptyOrUnknown: String {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return "unknown"
        }
        return value
    }
}
