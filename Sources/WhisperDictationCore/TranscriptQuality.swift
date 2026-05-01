import Foundation

public struct TranscriptQualityAssessment: Codable, Sendable {
    public let audioDurationMilliseconds: Double
    public let wordCount: Int
    public let characterCount: Int
    public let wordsPerSecond: Double
    public let charactersPerSecond: Double
    public let requiresSecondPass: Bool
    public let reason: String?
}

public enum TranscriptQuality {
    private static let longAudioThresholdMilliseconds = 8_000.0
    private static let minimumWordsPerSecond = 0.80
    private static let minimumCharactersPerSecond = 4.50

    public static func assess(text: String, audioDurationMilliseconds: Double) -> TranscriptQualityAssessment {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let characterCount = normalized.filter { !$0.isWhitespace }.count
        let seconds = max(audioDurationMilliseconds / 1_000.0, 0.001)
        let wordsPerSecond = Double(words.count) / seconds
        let charactersPerSecond = Double(characterCount) / seconds

        let longAudioLooksTooShort = audioDurationMilliseconds >= longAudioThresholdMilliseconds
            && !normalized.isEmpty
            && wordsPerSecond < minimumWordsPerSecond
            && charactersPerSecond < minimumCharactersPerSecond

        return TranscriptQualityAssessment(
            audioDurationMilliseconds: audioDurationMilliseconds,
            wordCount: words.count,
            characterCount: characterCount,
            wordsPerSecond: wordsPerSecond,
            charactersPerSecond: charactersPerSecond,
            requiresSecondPass: longAudioLooksTooShort,
            reason: longAudioLooksTooShort ? "long-audio-short-transcript" : nil
        )
    }
}
