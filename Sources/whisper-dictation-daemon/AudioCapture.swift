@preconcurrency import AVFoundation
import Foundation
import WhisperDictationCore

struct StoppedCapture {
    let sessionId: String
    let startedAt: Date
    let prebufferMilliseconds: Double
    let samples: [Int16]
    let signalMetrics: AudioSignalMetrics
}

struct AudioSignalMetrics: Sendable {
    let peakDecibels: Double
    let rmsDecibels: Double
    let probablySilent: Bool
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
    private static let silentPeakThresholdDecibels = -50.0
    private static let silentRMSThresholdDecibels = -55.0

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
    private let converterLock = NSLock()
    private let lifecycleQueue = DispatchQueue(label: "whisper.dictation.capture.lifecycle")
    private var activeSession: ActiveCaptureSession?
    private var startupSemaphore = DispatchSemaphore(value: 0)
    private var startupSignaled = false
    private var configurationObserver: NSObjectProtocol?
    private var restartInFlight = false

    private(set) var engineStartupMilliseconds: Double?
    private(set) var defaultInputDeviceName: String?

    init(config: AppConfig) {
        self.config = config
        let ringCapacity = Int(Double(config.prebufferMilliseconds) * 16.0)
        self.ringBuffer = Int16RingBuffer(capacity: ringCapacity)
        self.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRestart(reason: "audio engine configuration changed")
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() throws {
        try lifecycleQueue.sync {
            try startEngineLocked()
        }
    }

    func stop() {
        lifecycleQueue.sync {
            stopEngineLocked()
        }
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
        var capture: StoppedCapture?

        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard let session = activeSession else {
            throw AudioCaptureError.noActiveSession
        }

        activeSession = nil
        guard !discard else {
            return nil
        }

        let signalMetrics = Self.analyze(samples: session.samples)
        capture = StoppedCapture(
            sessionId: session.sessionId,
            startedAt: session.startedAt,
            prebufferMilliseconds: session.prebufferMilliseconds,
            samples: session.samples,
            signalMetrics: signalMetrics
        )

        if signalMetrics.probablySilent {
            let reason = String(
                format: "silent capture detected (peak %.1f dBFS, rms %.1f dBFS)",
                signalMetrics.peakDecibels,
                signalMetrics.rmsDecibels
            )
            scheduleRestart(reason: reason)
        }

        return capture
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
        converterLock.lock()
        guard let converter else {
            converterLock.unlock()
            return
        }
        converterLock.unlock()

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

        converterLock.lock()
        if !startupSignaled {
            startupSignaled = true
            let semaphore = startupSemaphore
            converterLock.unlock()
            semaphore.signal()
            return
        }
        converterLock.unlock()
    }

    private func startEngineLocked() throws {
        defaultInputDeviceName = try CoreAudioDevice.ensurePreferredInputDevice(
            named: config.preferredInputDevice,
            enforceAsDefault: config.enforcePreferredInputDevice
        )

        stopEngineLocked()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterInitializationFailed
        }

        let startupSemaphore = DispatchSemaphore(value: 0)
        converterLock.lock()
        self.converter = converter
        self.startupSemaphore = startupSemaphore
        self.startupSignaled = false
        converterLock.unlock()

        let startNs = DispatchTime.now().uptimeNanoseconds
        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(config.audioBufferSizeFrames),
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        do {
            try engine.start()
        } catch {
            stopEngineLocked()
            throw error
        }

        guard startupSemaphore.wait(timeout: .now() + .seconds(2)) == .success else {
            stopEngineLocked()
            throw AudioCaptureError.startupTimedOut
        }

        let endNs = DispatchTime.now().uptimeNanoseconds
        engineStartupMilliseconds = Double(endNs - startNs) / 1_000_000.0
    }

    private func stopEngineLocked() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        converterLock.lock()
        converter = nil
        startupSemaphore = DispatchSemaphore(value: 0)
        startupSignaled = false
        converterLock.unlock()
    }

    private func scheduleRestart(reason: String) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            guard !self.restartInFlight else { return }
            self.restartInFlight = true
            defer { self.restartInFlight = false }

            fputs("whisper-dictation-daemon: restarting audio capture (\(reason))\n", stderr)

            do {
                try self.startEngineLocked()
            } catch {
                fputs("whisper-dictation-daemon: audio capture restart failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private static func analyze(samples: [Int16]) -> AudioSignalMetrics {
        guard !samples.isEmpty else {
            return AudioSignalMetrics(
                peakDecibels: -.infinity,
                rmsDecibels: -.infinity,
                probablySilent: true
            )
        }

        var peakMagnitude = 0.0
        var meanSquare = 0.0

        for sample in samples {
            let normalized = Double(abs(Int(sample))) / Double(Int16.max)
            peakMagnitude = max(peakMagnitude, normalized)
            meanSquare += normalized * normalized
        }

        let rmsMagnitude = sqrt(meanSquare / Double(samples.count))
        let peakDecibels = decibels(for: peakMagnitude)
        let rmsDecibels = decibels(for: rmsMagnitude)

        return AudioSignalMetrics(
            peakDecibels: peakDecibels,
            rmsDecibels: rmsDecibels,
            probablySilent: peakDecibels <= silentPeakThresholdDecibels && rmsDecibels <= silentRMSThresholdDecibels
        )
    }

    private static func decibels(for normalizedMagnitude: Double) -> Double {
        guard normalizedMagnitude > 0 else {
            return -.infinity
        }

        return 20.0 * log10(normalizedMagnitude)
    }
}
