import Foundation

public struct AppConfig: Codable, Sendable {
    public let controlHost: String
    public let controlPort: Int
    public let preferredInputDevice: String?
    public let enforcePreferredInputDevice: Bool
    public let prebufferMilliseconds: Int
    public let audioBufferSizeFrames: Int
    public let pollIntervalMilliseconds: Int
    public let whisperServerBinary: String
    public let whisperCliBinary: String
    public let whisperModelPath: String
    public let whisperServerHost: String
    public let whisperServerPort: Int
    public let tempDirectory: String
    public let salvageDirectory: String
    public let daemonLogPath: String
    public let whisperServerLogPath: String
    public let controlBinaryPath: String
    public let daemonBinaryPath: String
    public let warmServerOnLaunch: Bool
    public let whisperThreads: Int

    public static let defaultConfigPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Application Support/WhisperDictation/config.json"
        )

    public static func load(from path: String = AppConfig.defaultConfigPath) throws -> AppConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }
}

public struct AppPaths {
    public let tempDirectoryURL: URL
    public let salvageDirectoryURL: URL
    public let daemonLogURL: URL
    public let whisperServerLogURL: URL

    public init(config: AppConfig) {
        tempDirectoryURL = URL(fileURLWithPath: config.tempDirectory, isDirectory: true)
        salvageDirectoryURL = URL(fileURLWithPath: config.salvageDirectory, isDirectory: true)
        daemonLogURL = URL(fileURLWithPath: config.daemonLogPath, isDirectory: false)
        whisperServerLogURL = URL(fileURLWithPath: config.whisperServerLogPath, isDirectory: false)
    }

    public func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: salvageDirectoryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: daemonLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: whisperServerLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}
