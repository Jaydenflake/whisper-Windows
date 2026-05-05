import Foundation

public struct CaptureReadinessAssessment: Codable, Sendable {
    public let ready: Bool
    public let reason: String?
    public let secondsSinceLastBuffer: Double?
}

public enum CaptureReadiness {
    public static let maximumBufferAgeSeconds = 2.0

    public static func assess(
        engineRunning: Bool,
        startupSignaled: Bool,
        secondsSinceLastBuffer: Double?
    ) -> CaptureReadinessAssessment {
        let reason: String?
        if !engineRunning {
            reason = "capture-engine-stopped"
        } else if !startupSignaled {
            reason = "capture-buffer-missing"
        } else if let secondsSinceLastBuffer, secondsSinceLastBuffer > maximumBufferAgeSeconds {
            reason = "capture-buffer-stale"
        } else if secondsSinceLastBuffer == nil {
            reason = "capture-buffer-missing"
        } else {
            reason = nil
        }

        return CaptureReadinessAssessment(
            ready: reason == nil,
            reason: reason,
            secondsSinceLastBuffer: secondsSinceLastBuffer
        )
    }
}
