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
    private static let minimumStalledWallClockMilliseconds = 1_000.0
    private static let maximumStalledActiveAudioMilliseconds = 250.0
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

        let captureStalled = wallClock >= minimumStalledWallClockMilliseconds
            && activeAudio <= maximumStalledActiveAudioMilliseconds
            && dropped > maximumStalledActiveAudioMilliseconds
        let hasLargeGap = wallClock >= minimumWallClockMilliseconds
            && dropped > allowedDroppedMilliseconds
            && coverage < minimumCoverageRatio
        let reason: String?
        if captureStalled {
            reason = "capture-stalled"
        } else if hasLargeGap {
            reason = "capture-duration-gap"
        } else {
            reason = nil
        }

        return CaptureIntegrityAssessment(
            capturedAudioMilliseconds: capturedAudioMilliseconds,
            prebufferMilliseconds: prebufferMilliseconds,
            captureWallClockMilliseconds: wallClock,
            activeAudioMilliseconds: activeAudio,
            droppedMilliseconds: dropped,
            coverageRatio: coverage,
            requiresFailure: reason != nil,
            reason: reason
        )
    }
}
