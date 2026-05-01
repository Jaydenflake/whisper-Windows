import Foundation

public struct CaptureIntegrityAssessment: Codable, Sendable {
    public let capturedAudioMilliseconds: Double
    public let prebufferMilliseconds: Double
    public let captureWallClockMilliseconds: Double
    public let activeAudioMilliseconds: Double
    public let droppedMilliseconds: Double
    public let coverageRatio: Double
    public let requiresFailure: Bool
    public let reason: String?
}

public enum CaptureIntegrity {
    private static let minimumWallClockMilliseconds = 5_000.0
    private static let allowedDroppedMilliseconds = 2_000.0
    private static let minimumCoverageRatio = 0.80

    public static func assess(
        capturedAudioMilliseconds: Double,
        prebufferMilliseconds: Double,
        captureWallClockMilliseconds: Double
    ) -> CaptureIntegrityAssessment {
        let wallClock = max(captureWallClockMilliseconds, 0)
        let activeAudio = max(capturedAudioMilliseconds - max(prebufferMilliseconds, 0), 0)
        let dropped = max(wallClock - activeAudio, 0)
        let coverage = wallClock > 0 ? min(activeAudio / wallClock, 1) : 1

        let hasLargeGap = wallClock >= minimumWallClockMilliseconds
            && dropped > allowedDroppedMilliseconds
            && coverage < minimumCoverageRatio

        return CaptureIntegrityAssessment(
            capturedAudioMilliseconds: capturedAudioMilliseconds,
            prebufferMilliseconds: prebufferMilliseconds,
            captureWallClockMilliseconds: wallClock,
            activeAudioMilliseconds: activeAudio,
            droppedMilliseconds: dropped,
            coverageRatio: coverage,
            requiresFailure: hasLargeGap,
            reason: hasLargeGap ? "capture-duration-gap" : nil
        )
    }
}
