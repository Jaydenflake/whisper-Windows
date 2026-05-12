import Foundation

public struct AppConfig: Codable, Sendable {
    public static let defaultPersistRecentCaptures = false
    public static let defaultServerRequestTimeoutSeconds = 30.0
    public static let defaultCLITimeoutSeconds = 90.0
    public static let allowedControlHosts = ["127.0.0.1", "localhost", "::1"]

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
    public let whisperVADModelPath: String?
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
    public let persistRecentCaptures: Bool
    public let serverRequestTimeoutSeconds: Double
    public let cliTimeoutSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case controlHost
        case controlPort
        case preferredInputDevice
        case enforcePreferredInputDevice
        case prebufferMilliseconds
        case audioBufferSizeFrames
        case pollIntervalMilliseconds
        case whisperServerBinary
        case whisperCliBinary
        case whisperModelPath
        case whisperVADModelPath
        case whisperServerHost
        case whisperServerPort
        case tempDirectory
        case salvageDirectory
        case daemonLogPath
        case whisperServerLogPath
        case controlBinaryPath
        case daemonBinaryPath
        case warmServerOnLaunch
        case whisperThreads
        case persistRecentCaptures
        case serverRequestTimeoutSeconds
        case cliTimeoutSeconds
    }

    public static let defaultConfigPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Application Support/WhisperDictation/config.json"
        )

    public static func load(from path: String = AppConfig.defaultConfigPath) throws -> AppConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        controlHost = try container.decode(String.self, forKey: .controlHost)
        guard Self.isLoopbackControlHost(controlHost) else {
            throw DecodingError.dataCorruptedError(
                forKey: .controlHost,
                in: container,
                debugDescription: "controlHost must be loopback-only: \(Self.allowedControlHosts.joined(separator: ", "))"
            )
        }

        controlPort = try container.decode(Int.self, forKey: .controlPort)
        preferredInputDevice = try container.decodeIfPresent(String.self, forKey: .preferredInputDevice)
        enforcePreferredInputDevice = try container.decode(Bool.self, forKey: .enforcePreferredInputDevice)
        prebufferMilliseconds = try container.decode(Int.self, forKey: .prebufferMilliseconds)
        audioBufferSizeFrames = try container.decode(Int.self, forKey: .audioBufferSizeFrames)
        pollIntervalMilliseconds = try container.decode(Int.self, forKey: .pollIntervalMilliseconds)
        whisperServerBinary = try container.decode(String.self, forKey: .whisperServerBinary)
        whisperCliBinary = try container.decode(String.self, forKey: .whisperCliBinary)
        whisperModelPath = try container.decode(String.self, forKey: .whisperModelPath)
        whisperVADModelPath = try container.decodeIfPresent(String.self, forKey: .whisperVADModelPath)
        whisperServerHost = try container.decode(String.self, forKey: .whisperServerHost)
        whisperServerPort = try container.decode(Int.self, forKey: .whisperServerPort)
        tempDirectory = try container.decode(String.self, forKey: .tempDirectory)
        salvageDirectory = try container.decode(String.self, forKey: .salvageDirectory)
        daemonLogPath = try container.decode(String.self, forKey: .daemonLogPath)
        whisperServerLogPath = try container.decode(String.self, forKey: .whisperServerLogPath)
        controlBinaryPath = try container.decode(String.self, forKey: .controlBinaryPath)
        daemonBinaryPath = try container.decode(String.self, forKey: .daemonBinaryPath)
        warmServerOnLaunch = try container.decode(Bool.self, forKey: .warmServerOnLaunch)
        whisperThreads = try container.decode(Int.self, forKey: .whisperThreads)
        persistRecentCaptures = try container.decodeIfPresent(Bool.self, forKey: .persistRecentCaptures)
            ?? Self.defaultPersistRecentCaptures
        let serverRequestTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .serverRequestTimeoutSeconds)
            ?? Self.defaultServerRequestTimeoutSeconds
        let cliTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .cliTimeoutSeconds)
            ?? Self.defaultCLITimeoutSeconds
        guard serverRequestTimeoutSeconds > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .serverRequestTimeoutSeconds,
                in: container,
                debugDescription: "serverRequestTimeoutSeconds must be positive"
            )
        }
        guard cliTimeoutSeconds > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .cliTimeoutSeconds,
                in: container,
                debugDescription: "cliTimeoutSeconds must be positive"
            )
        }
        self.serverRequestTimeoutSeconds = serverRequestTimeoutSeconds
        self.cliTimeoutSeconds = cliTimeoutSeconds
    }

    public static func isLoopbackControlHost(_ host: String) -> Bool {
        allowedControlHosts.contains(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
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
