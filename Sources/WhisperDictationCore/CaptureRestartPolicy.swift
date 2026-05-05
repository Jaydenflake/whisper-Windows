import Foundation

public enum CaptureRestartAction: String, Codable, Sendable {
    case retry
    case restartProcess
}

public struct CaptureRestartDecision: Codable, Sendable {
    public let action: CaptureRestartAction
    public let reason: String
}

public enum CaptureRestartPolicy {
    public static let maximumConsecutiveFailures = 3

    public static func assess(consecutiveFailureCount: Int) -> CaptureRestartDecision {
        if consecutiveFailureCount >= maximumConsecutiveFailures {
            return CaptureRestartDecision(
                action: .restartProcess,
                reason: "capture-restart-failed-repeatedly"
            )
        }

        return CaptureRestartDecision(
            action: .retry,
            reason: "capture-restart-failed"
        )
    }
}
