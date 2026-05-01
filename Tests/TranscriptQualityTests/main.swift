import Foundation
import WhisperDictationCore

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private func testLongAudioWithTinyTranscriptNeedsSecondPass() {
    let assessment = TranscriptQuality.assess(
        text: "Okay. Go ahead.",
        audioDurationMilliseconds: 45_000
    )

    expect(assessment.requiresSecondPass, "long audio with tiny transcript should require a second pass")
    expect(assessment.reason == "long-audio-short-transcript", "expected long-audio-short-transcript reason")
}

private func testLongAudioWithExpectedWordVolumeDoesNotNeedSecondPass() {
    let text = Array(repeating: "voice typing should preserve the full task clearly", count: 8)
        .joined(separator: " ")

    let assessment = TranscriptQuality.assess(
        text: text,
        audioDurationMilliseconds: 45_000
    )

    expect(!assessment.requiresSecondPass, "normal long transcript should not require a second pass")
    expect(assessment.reason == nil, "normal long transcript should not have a quality reason")
}

private func testShortAudioWithShortTranscriptDoesNotNeedSecondPass() {
    let assessment = TranscriptQuality.assess(
        text: "Yes.",
        audioDurationMilliseconds: 1_200
    )

    expect(!assessment.requiresSecondPass, "short dictation should not require a second pass")
    expect(assessment.reason == nil, "short dictation should not have a quality reason")
}

private func testReportedLongTaskFailureNeedsSecondPass() {
    let badTranscript = """
    Okay we need to basically go from our standard right now we are space for a I'll see in.
    Much as possible.
    The best is can you please investigate and. Yeah. Go ahead and. Come with a good game plan.
    """

    let assessment = TranscriptQuality.assess(
        text: badTranscript,
        audioDurationMilliseconds: 60_000
    )

    expect(assessment.requiresSecondPass, "reported long-task failure should require a second pass")
    expect(assessment.reason == "long-audio-short-transcript", "reported failure should have the expected reason")
}

testLongAudioWithTinyTranscriptNeedsSecondPass()
testLongAudioWithExpectedWordVolumeDoesNotNeedSecondPass()
testShortAudioWithShortTranscriptDoesNotNeedSecondPass()
testReportedLongTaskFailureNeedsSecondPass()
print("TranscriptQualityTests passed")
