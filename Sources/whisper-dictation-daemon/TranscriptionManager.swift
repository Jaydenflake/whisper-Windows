import Foundation
import WhisperDictationCore

private struct PendingTranscription {
    let capture: StoppedCapture
    let wavData: Data
    let wavURL: URL
    let enqueuedAt: Date
}

private final class URLRequestResponseBox: @unchecked Sendable {
    var data: Data?
    var error: Error?
    var healthy = false
    var statusCode: Int?
}

private enum ServerState: String {
    case stopped
    case starting
    case ready
}

private enum TranscriptOutcome {
    case text(String)
    case noSpeech
}

private enum TranscriptionError: LocalizedError {
    case serverHTTPError(Int)
    case serverNoResponse
    case cliFailed(String)
    case combined(server: Error, cli: Error)

    var errorDescription: String? {
        switch self {
        case .serverHTTPError(let statusCode):
            return "whisper-server returned HTTP \(statusCode)"
        case .serverNoResponse:
            return "No response body from whisper-server"
        case .cliFailed(let details):
            return details
        case .combined(let server, let cli):
            return "Server failed: \(server.localizedDescription). CLI fallback failed: \(cli.localizedDescription)"
        }
    }
}

final class TranscriptionManager: @unchecked Sendable {
    private let config: AppConfig
    private let paths: AppPaths
    private let onCompleted: @Sendable (SessionResultPayload) -> Void
    private let queue = DispatchQueue(label: "whisper.dictation.transcription", qos: .utility)

    private var pending = [PendingTranscription]()
    private var processing = false
    private var serverProcess: Process?
    private var serverState: ServerState = .stopped

    init(config: AppConfig, paths: AppPaths, onCompleted: @escaping @Sendable (SessionResultPayload) -> Void) {
        self.config = config
        self.paths = paths
        self.onCompleted = onCompleted
    }

    func prewarmServerIfNeeded() {
        guard config.warmServerOnLaunch else {
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            _ = try? self.ensureServerReady(timeout: 15.0)
        }
    }

    func enqueue(_ capture: StoppedCapture) {
        let wavURL = paths.tempDirectoryURL.appendingPathComponent("\(capture.sessionId).wav")
        queue.async { [weak self] in
            guard let self else { return }

            let pending = PendingTranscription(
                capture: capture,
                wavData: WAVFileWriter.mono16BitPCMData(samples: capture.samples, sampleRate: 16_000),
                wavURL: wavURL,
                enqueuedAt: Date()
            )

            self.pending.append(pending)
            self.processNextIfNeeded()
        }
    }

    func pendingCount() -> Int {
        queue.sync {
            pending.count + (processing ? 1 : 0)
        }
    }

    func currentServerState() -> String {
        queue.sync {
            serverState.rawValue
        }
    }

    func stop() {
        queue.sync {
            if let serverProcess, serverProcess.isRunning {
                serverProcess.terminate()
                serverProcess.waitUntilExit()
            }
            self.serverProcess = nil
            self.serverState = .stopped
        }
    }

    private func processNextIfNeeded() {
        guard !processing, !pending.isEmpty else {
            return
        }

        processing = true
        let next = pending.removeFirst()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let completed = self.transcribe(next)
            self.queue.async {
                self.processing = false
                self.onCompleted(completed)
                self.processNextIfNeeded()
            }
        }
    }

    private func transcribe(_ pending: PendingTranscription) -> SessionResultPayload {
        let queueWaitMs = pending.enqueuedAt.timeIntervalSince(
            pending.capture.startedAt.addingTimeInterval(Double(pending.capture.samples.count) / 16_000.0)
        ) * 1000.0
        let start = Date()
        let diskStatus = currentDiskStatus()

        if pending.capture.signalMetrics.probablySilent {
            return noSpeechResult(
                for: pending.capture,
                transcriptionMode: "silent-capture",
                start: start,
                queueWaitMs: queueWaitMs
            )
        }

        do {
            switch try transcribeViaServerWithRecovery(pending) {
            case .text(let text):
                return completedResult(
                    for: pending.capture,
                    text: text,
                    transcriptionMode: "server",
                    start: start,
                    queueWaitMs: queueWaitMs
                )
            case .noSpeech:
                guard shouldAttemptCLIFallback(for: pending.capture, diskStatus: diskStatus) else {
                    return noSpeechResult(
                        for: pending.capture,
                        transcriptionMode: "no-speech",
                        start: start,
                        queueWaitMs: queueWaitMs
                    )
                }

                do {
                    switch try transcribeViaCLI(pending) {
                    case .text(let text):
                        return completedResult(
                            for: pending.capture,
                            text: text,
                            transcriptionMode: "cli",
                            start: start,
                            queueWaitMs: queueWaitMs
                        )
                    case .noSpeech:
                        return noSpeechResult(
                            for: pending.capture,
                            transcriptionMode: "no-speech",
                            start: start,
                            queueWaitMs: queueWaitMs
                        )
                    }
                } catch {
                    fputs(
                        "whisper-dictation-daemon: CLI fallback after no-speech result failed: \(error.localizedDescription)\n",
                        stderr
                    )
                    return noSpeechResult(
                        for: pending.capture,
                        transcriptionMode: "no-speech",
                        start: start,
                        queueWaitMs: queueWaitMs
                    )
                }
            }
        } catch let serverError {
            do {
                switch try transcribeViaCLI(pending) {
                case .text(let text):
                    return completedResult(
                        for: pending.capture,
                        text: text,
                        transcriptionMode: "cli",
                        start: start,
                        queueWaitMs: queueWaitMs
                    )
                case .noSpeech:
                    return noSpeechResult(
                        for: pending.capture,
                        transcriptionMode: "no-speech",
                        start: start,
                        queueWaitMs: queueWaitMs
                    )
                }
            } catch let cliError {
                return failedResult(
                    for: pending,
                    error: TranscriptionError.combined(server: serverError, cli: cliError),
                    diskStatus: diskStatus
                )
            }
        }
    }

    private func completedResult(
        for capture: StoppedCapture,
        text: String,
        transcriptionMode: String,
        start: Date,
        queueWaitMs: Double
    ) -> SessionResultPayload {
        let metrics = SessionMetrics(
            sessionId: capture.sessionId,
            prebufferMilliseconds: capture.prebufferMilliseconds,
            audioDurationMilliseconds: Double(capture.samples.count) / 16.0,
            transcriptionMode: transcriptionMode,
            transcriptionMilliseconds: Date().timeIntervalSince(start) * 1000.0,
            queueWaitMilliseconds: max(queueWaitMs, 0),
            completedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )

        return SessionResultPayload(
            sessionId: capture.sessionId,
            text: text,
            metrics: metrics,
            salvagePath: nil,
            errorMessage: nil
        )
    }

    private func noSpeechResult(
        for capture: StoppedCapture,
        transcriptionMode: String,
        start: Date,
        queueWaitMs: Double
    ) -> SessionResultPayload {
        let metrics = SessionMetrics(
            sessionId: capture.sessionId,
            prebufferMilliseconds: capture.prebufferMilliseconds,
            audioDurationMilliseconds: Double(capture.samples.count) / 16.0,
            transcriptionMode: transcriptionMode,
            transcriptionMilliseconds: Date().timeIntervalSince(start) * 1000.0,
            queueWaitMilliseconds: max(queueWaitMs, 0),
            completedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )

        return SessionResultPayload(
            sessionId: capture.sessionId,
            text: "",
            metrics: metrics,
            salvagePath: nil,
            errorMessage: nil
        )
    }

    private func failedResult(
        for pending: PendingTranscription,
        error: Error,
        diskStatus: DiskSpaceStatus?
    ) -> SessionResultPayload {
        let metrics = SessionMetrics(
            sessionId: pending.capture.sessionId,
            prebufferMilliseconds: pending.capture.prebufferMilliseconds,
            audioDurationMilliseconds: Double(pending.capture.samples.count) / 16.0,
            transcriptionMode: "failed",
            transcriptionMilliseconds: nil,
            queueWaitMilliseconds: nil,
            completedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )

        let salvagePath = persistSalvage(for: pending)
        let errorMessage = userFacingErrorMessage(for: error, diskStatus: diskStatus)
        fputs(
            "whisper-dictation-daemon: transcription failed: \(errorMessage) [\(error.localizedDescription)]\n",
            stderr
        )

        return SessionResultPayload(
            sessionId: pending.capture.sessionId,
            text: "",
            metrics: metrics,
            salvagePath: salvagePath,
            errorMessage: errorMessage
        )
    }

    private func ensureServerReady(timeout: TimeInterval) throws {
        if isServerHealthySync() {
            serverState = .ready
            return
        }

        if serverProcess == nil || serverProcess?.isRunning == false {
            try launchServer()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isServerHealthySync() {
                serverState = .ready
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw NSError(
            domain: "WhisperDictation",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "whisper-server did not become ready"]
        )
    }

    private func launchServer() throws {
        serverState = .starting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperServerBinary)
        process.arguments = [
            "-m", config.whisperModelPath,
            "--host", config.whisperServerHost,
            "--port", String(config.whisperServerPort),
            "-t", String(config.whisperThreads),
        ]

        let logHandle = try ensureWritableLog(at: paths.whisperServerLogURL)
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        serverProcess = process
    }

    private func restartServer() throws {
        if let serverProcess, serverProcess.isRunning {
            serverProcess.terminate()
            serverProcess.waitUntilExit()
        }
        self.serverProcess = nil
        serverState = .stopped
        try ensureServerReady(timeout: 15.0)
    }

    private func transcribeViaServerWithRecovery(_ pending: PendingTranscription) throws -> TranscriptOutcome {
        do {
            try ensureServerReady(timeout: 15.0)
            return try transcribeViaServer(
                wavData: pending.wavData,
                filename: pending.wavURL.lastPathComponent
            )
        } catch {
            try restartServer()
            return try transcribeViaServer(
                wavData: pending.wavData,
                filename: pending.wavURL.lastPathComponent
            )
        }
    }

    private func transcribeViaServer(wavData: Data, filename: String) throws -> TranscriptOutcome {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(
            url: URL(string: "http://\(config.whisperServerHost):\(config.whisperServerPort)/inference")!
        )
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(multipartField(name: "response_format", value: "json", boundary: boundary))
        body.append(multipartField(name: "no_timestamps", value: "true", boundary: boundary))
        body.append(multipartField(name: "temperature", value: "0.0", boundary: boundary))
        body.append(
            multipartFile(
                name: "file",
                filename: filename,
                mimeType: "audio/wav",
                data: wavData,
                boundary: boundary
            )
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = URLRequestResponseBox()

        URLSession.shared.dataTask(with: request) { data, response, error in
            responseBox.data = data
            responseBox.error = error
            responseBox.statusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let responseError = responseBox.error {
            throw responseError
        }

        if let statusCode = responseBox.statusCode, statusCode != 200 {
            throw TranscriptionError.serverHTTPError(statusCode)
        }

        guard let responseData = responseBox.data else {
            throw TranscriptionError.serverNoResponse
        }

        let payload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        return normalizeTranscript((payload?["text"] as? String) ?? "")
    }

    private func transcribeViaCLI(_ pending: PendingTranscription) throws -> TranscriptOutcome {
        let wavURL = try materializeWAV(for: pending)
        defer {
            try? FileManager.default.removeItem(at: wavURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperCliBinary)
        process.arguments = [
            "-m", config.whisperModelPath,
            "-f", wavURL.path,
            "-nt",
            "-np",
            "-t", String(config.whisperThreads),
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = details.isEmpty
                ? (fallback.isEmpty ? "whisper-cli failed" : "whisper-cli failed: \(fallback)")
                : "whisper-cli failed: \(details)"
            throw TranscriptionError.cliFailed(message)
        }

        return normalizeTranscript(stdout)
    }

    private func materializeWAV(for pending: PendingTranscription) throws -> URL {
        try pending.wavData.write(to: pending.wavURL, options: .atomic)
        return pending.wavURL
    }

    private func isServerHealthySync() -> Bool {
        guard let url = URL(string: "http://\(config.whisperServerHost):\(config.whisperServerPort)/") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 0.25
        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = URLRequestResponseBox()

        URLSession.shared.dataTask(with: request) { _, response, error in
            if error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200 {
                responseBox.healthy = true
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + .milliseconds(300))
        return responseBox.healthy
    }

    private func multipartField(name: String, value: String, boundary: String) -> Data {
        var field = Data()
        field.append("--\(boundary)\r\n".data(using: .utf8)!)
        field.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        field.append("\(value)\r\n".data(using: .utf8)!)
        return field
    }

    private func multipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) -> Data {
        var file = Data()
        file.append("--\(boundary)\r\n".data(using: .utf8)!)
        file.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        file.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        file.append(data)
        file.append("\r\n".data(using: .utf8)!)
        return file
    }

    private func ensureWritableLog(at url: URL) throws -> FileHandle {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func normalizeTranscript(_ text: String) -> TranscriptOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .noSpeech
        }

        let marker = trimmed
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        if [
            "[BLANKAUDIO]",
            "(BLANKAUDIO)",
            "[NOSPEECH]",
            "(NOSPEECH)",
            "[SILENCE]",
            "(SILENCE)",
        ].contains(marker) {
            return .noSpeech
        }

        guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else {
            return .noSpeech
        }

        return .text(trimmed)
    }

    private func persistSalvage(for pending: PendingTranscription) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let salvageURL = paths.salvageDirectoryURL.appendingPathComponent("whisper-\(stamp)-\(pending.capture.sessionId).wav")

        do {
            try pending.wavData.write(to: salvageURL, options: .atomic)
            return salvageURL.path
        } catch {
            fputs(
                "whisper-dictation-daemon: unable to save salvage audio: \(error.localizedDescription)\n",
                stderr
            )
            return nil
        }
    }

    private func currentDiskStatus() -> DiskSpaceStatus? {
        DiskSpaceMonitor.currentStatus(for: paths.tempDirectoryURL.path)
    }

    private func shouldAttemptCLIFallback(for capture: StoppedCapture, diskStatus: DiskSpaceStatus?) -> Bool {
        guard diskStatus?.criticalSpace != true else {
            return false
        }

        let audioDurationMilliseconds = Double(capture.samples.count) / 16.0
        return audioDurationMilliseconds >= 1_500
    }

    private func userFacingErrorMessage(for error: Error, diskStatus: DiskSpaceStatus?) -> String {
        if isOutOfDiskSpace(error), let diskStatus {
            return "Disk Almost Full (\(diskStatus.summary) free)"
        }

        if let diskStatus, diskStatus.criticalSpace {
            return "Disk Almost Full (\(diskStatus.summary) free)"
        }

        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "Transcription Failed" : description
    }

    private func isOutOfDiskSpace(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
            return true
        }

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }

        let description = nsError.localizedDescription.lowercased()
        return description.contains("no space") || description.contains("disk is full")
    }
}
