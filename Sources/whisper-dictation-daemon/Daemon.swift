import Foundation
import WhisperDictationCore

final class WhisperDictationDaemon: @unchecked Sendable {
    private let config: AppConfig
    private let paths: AppPaths
    private let captureEngine: AudioCaptureEngine
    private let completedLock = NSLock()
    private let shutdownLock = NSLock()
    private var completedResults = [SessionResultPayload]()
    private var server: JSONSocketServer?
    private var signalSources = [DispatchSourceSignal]()
    private var shuttingDown = false
    private lazy var transcriptionManager: TranscriptionManager = {
        TranscriptionManager(config: config, paths: paths) { [weak self] result in
            self?.storeCompleted(result)
        }
    }()

    init(config: AppConfig) throws {
        self.config = config
        self.paths = AppPaths(config: config)
        try paths.ensureDirectoriesExist()
        self.captureEngine = AudioCaptureEngine(config: config)
    }

    func run() throws {
        try captureEngine.start()
        transcriptionManager.prewarmServerIfNeeded()

        let server = JSONSocketServer(host: config.controlHost, port: config.controlPort) { [weak self] request in
            guard let self else {
                return ControlResponse(ok: false, error: "Daemon unavailable")
            }
            return self.handle(request)
        }
        self.server = server
        try server.start()
        installSignalHandlers()
        dispatchMain()
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.command {
        case .warmup:
            return ControlResponse(ok: true)
        case .start:
            return handleStart()
        case .stop:
            return handleStop(discard: false)
        case .cancel:
            return handleStop(discard: true)
        case .nextResult:
            return handleNextResult()
        case .status:
            return handleStatus()
        case .shutdown:
            return handleShutdown()
        }
    }

    private func handleStart() -> ControlResponse {
        do {
            let started = try captureEngine.startSession()
            var response = ControlResponse(ok: true)
            response.recording = true
            response.pendingCount = transcriptionManager.pendingCount()
            response.sessionId = started.sessionId
            response.status = makeStatusPayload(recording: true)
            return response
        } catch {
            return ControlResponse(ok: false, error: error.localizedDescription)
        }
    }

    private func handleStop(discard: Bool) -> ControlResponse {
        do {
            let capture = try captureEngine.stopSession(discard: discard)
            if let capture {
                transcriptionManager.enqueue(capture)
            }
            var response = ControlResponse(ok: true)
            response.recording = false
            response.pendingCount = transcriptionManager.pendingCount()
            response.sessionId = capture?.sessionId
            response.status = makeStatusPayload(recording: false)
            return response
        } catch {
            return ControlResponse(ok: false, error: error.localizedDescription)
        }
    }

    private func handleNextResult() -> ControlResponse {
        completedLock.lock()
        let result = completedResults.isEmpty ? nil : completedResults.removeFirst()
        completedLock.unlock()

        var response = ControlResponse(ok: true)
        response.resultAvailable = (result != nil)
        response.result = result
        response.pendingCount = transcriptionManager.pendingCount()
        response.recording = captureEngine.isRecording()
        return response
    }

    private func handleStatus() -> ControlResponse {
        var response = ControlResponse(ok: true)
        response.recording = captureEngine.isRecording()
        response.pendingCount = transcriptionManager.pendingCount()
        response.status = makeStatusPayload(recording: captureEngine.isRecording())
        return response
    }

    private func handleShutdown() -> ControlResponse {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.shutdownAndExit(code: EXIT_SUCCESS)
        }

        return ControlResponse(ok: true)
    }

    private func makeStatusPayload(recording: Bool) -> StatusPayload {
        let diskStatus = DiskSpaceMonitor.currentStatus(for: paths.tempDirectoryURL.path)
        let captureReadiness = captureEngine.readinessAssessment()
        return StatusPayload(
            recording: recording,
            pendingCount: transcriptionManager.pendingCount(),
            engineReady: captureReadiness.ready,
            engineHealthMessage: captureHealthMessage(from: captureReadiness),
            engineStartupMilliseconds: captureEngine.engineStartupMilliseconds,
            prebufferAvailableMilliseconds: captureEngine.prebufferAvailableMilliseconds(),
            preferredInputDevice: config.preferredInputDevice,
            defaultInputDevice: captureEngine.defaultInputDeviceName,
            serverState: transcriptionManager.currentServerState(),
            availableDiskSpaceBytes: diskStatus?.availableBytes,
            lowDiskSpaceMessage: lowDiskSpaceMessage(from: diskStatus)
        )
    }

    private func storeCompleted(_ result: SessionResultPayload) {
        completedLock.lock()
        completedResults.append(result)
        completedLock.unlock()
    }

    private func installSignalHandlers() {
        for signal in [SIGTERM, SIGINT] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
            source.setEventHandler { [weak self] in
                self?.shutdownAndExit(code: EXIT_SUCCESS)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdownAndExit(code: Int32) {
        shutdownLock.lock()
        if shuttingDown {
            shutdownLock.unlock()
            return
        }
        shuttingDown = true
        shutdownLock.unlock()

        server?.stop()
        transcriptionManager.stop()
        captureEngine.stop()
        exit(code)
    }

    private func lowDiskSpaceMessage(from diskStatus: DiskSpaceStatus?) -> String? {
        guard let diskStatus, diskStatus.lowSpace else {
            return nil
        }

        return "Disk Almost Full (\(diskStatus.summary) free)"
    }

    private func captureHealthMessage(from readiness: CaptureReadinessAssessment) -> String? {
        guard !readiness.ready else {
            return nil
        }

        switch readiness.reason {
        case "capture-engine-stopped":
            return "Audio Input Recovering"
        case "capture-buffer-missing":
            return "Audio Input Warming Up"
        case "capture-buffer-stale":
            return "Audio Input Stalled"
        default:
            return "Audio Input Not Ready"
        }
    }
}
