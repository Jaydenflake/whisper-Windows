import Foundation

public struct DiskSpaceStatus: Codable, Sendable {
    public let availableBytes: Int64
    public let lowSpace: Bool
    public let criticalSpace: Bool
    public let summary: String

    public init(availableBytes: Int64, lowSpace: Bool, criticalSpace: Bool, summary: String) {
        self.availableBytes = availableBytes
        self.lowSpace = lowSpace
        self.criticalSpace = criticalSpace
        self.summary = summary
    }
}

public enum DiskSpaceMonitor {
    public static let lowSpaceThresholdBytes: Int64 = 512 * 1024 * 1024
    public static let criticalSpaceThresholdBytes: Int64 = 192 * 1024 * 1024

    public static func currentStatus(for path: String) -> DiskSpaceStatus? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            guard let availableBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
                return nil
            }
            return status(forAvailableBytes: availableBytes)
        } catch {
            return nil
        }
    }

    public static func status(forAvailableBytes availableBytes: Int64) -> DiskSpaceStatus {
        DiskSpaceStatus(
            availableBytes: availableBytes,
            lowSpace: availableBytes <= lowSpaceThresholdBytes,
            criticalSpace: availableBytes <= criticalSpaceThresholdBytes,
            summary: formattedBytes(availableBytes)
        )
    }

    public static func formattedBytes(_ availableBytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
    }
}
