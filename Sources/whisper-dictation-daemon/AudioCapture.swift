@preconcurrency import AVFoundation
import Foundation
import WhisperDictationCore

struct StoppedCapture {
    let sessionId: String
    let startedAt: Date
    let prebufferMilliseconds: Double
    let samples: [Int16]
}

enum AudioCaptureError: Error, LocalizedError {
    case startupTimedOut
    case converterInitializationFailed
    case alreadyRecording
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .startupTimedOut:
            return "Audio capture did not become ready in time."
        case .converterInitializationFailed:
            return "Unable to initialize the audio converter."
        case .alreadyRecording:
            return "A recording is already active."
        case .noActiveSession:
            return "There is no active recording session."
        }
    }
}

private final class ActiveCaptureSession {
    let sessionId: String
    let startedAt: Date
    let prebufferMilliseconds: Double
    var samples: [Int16]

    init(sessionId: String, startedAt: Date, prebufferMilliseconds: Double, samples: [Int16]) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.prebufferMilliseconds = prebufferMilliseconds
        self.samples = samples
    }
}

private final class ConverterFeedState: @unchecked Sendable {
    var used = false
}

final class AudioCaptureEngine: @unchecked Sendable {
    private let config: AppConfig
    private let ringBuffer: Int16RingBuffer
    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    private var converter: AVAudioConverter?
    private let sessionLock = NSLock()
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private var activeSession: ActiveCaptureSession?
    private var startupSignaled = false

    private(set) var engineStartupMilliseconds: Double?
    private(set) var defaultInputDeviceName: String?

    init(config: AppConfig) {
        self.config = config
        let ringCapacity = Int(Double(config.prebufferMilliseconds) * 16.0)
        self.ringBuffer = Int16RingBuffer(capacity: ringCapacity)
    }

    func start() throws {
        defaultInputDeviceName = try CoreAudioDevice.ensurePreferredInputDevice(
            named: config.preferredInputDevice,
            enforceAsDefault: config.enforcePreferredInputDevice
        )

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterInitializationFailed
        }
        self.converter = converter

        let startNs = DispatchTime.now().uptimeNanoseconds
        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(config.audioBufferSizeFrames),
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        try engine.start()
        guard startupSemaphore.wait(timeout: .now() + .seconds(2)) == .success else {
            throw AudioCaptureError.startupTimedOut
        }

        let endNs = DispatchTime.now().uptimeNanoseconds
        engineStartupMilliseconds = Double(endNs - startNs) / 1_000_000.0
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func startSession() throws -> (sessionId: String, prebufferMilliseconds: Double) {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard activeSession == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        let prebufferSamples = ringBuffer.snapshot()
        let prebufferMilliseconds = Double(prebufferSamples.count) / 16.0
        let sessionId = UUID().uuidString.lowercased()

        activeSession = ActiveCaptureSession(
            sessionId: sessionId,
            startedAt: Date(),
            prebufferMilliseconds: prebufferMilliseconds,
            samples: prebufferSamples
        )

        return (sessionId: sessionId, prebufferMilliseconds: prebufferMilliseconds)
    }

    func stopSession(discard: Bool) throws -> StoppedCapture? {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard let session = activeSession else {
            throw AudioCaptureError.noActiveSession
        }

        activeSession = nil
        guard !discard else {
            return nil
        }

        return StoppedCapture(
            sessionId: session.sessionId,
            startedAt: session.startedAt,
            prebufferMilliseconds: session.prebufferMilliseconds,
            samples: session.samples
        )
    }

    func isRecording() -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return activeSession != nil
    }

    func prebufferAvailableMilliseconds() -> Double {
        ringBuffer.availableMilliseconds
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let converter else {
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var conversionError: NSError?
        let feedState = ConverterFeedState()
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if feedState.used {
                status.pointee = .noDataNow
                return nil
            }

            feedState.used = true
            status.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &conversionError, withInputFrom: inputBlock)
        guard conversionError == nil, convertedBuffer.frameLength > 0 else {
            return
        }

        guard let channelPointer = convertedBuffer.int16ChannelData?.pointee else {
            return
        }

        let sampleCount = Int(convertedBuffer.frameLength)
        let sampleBuffer = UnsafeBufferPointer(start: channelPointer, count: sampleCount)

        ringBuffer.append(sampleBuffer)

        sessionLock.lock()
        if let session = activeSession {
            session.samples.append(contentsOf: sampleBuffer)
        }
        sessionLock.unlock()

        if !startupSignaled {
            startupSignaled = true
            startupSemaphore.signal()
        }
    }
}
