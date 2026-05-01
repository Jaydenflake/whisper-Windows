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
    case text(String, TranscriptDiagnostic?)
    case noSpeech
}

private struct TranscriptDiagnostic {
    let reason: String
    let rawTranscript: String
    let cleanedTranscript: String
}

private enum TranscriptionError: LocalizedError {
    case serverHTTPError(Int)
    case serverNoResponse
    case cliFailed(String)
    case lowConfidence(String)
    case captureIncomplete(String)
    case combined(server: Error, cli: Error)

    var errorDescription: String? {
        switch self {
        case .serverHTTPError(let statusCode):
            return "whisper-server returned HTTP \(statusCode)"
        case .serverNoResponse:
            return "No response body from whisper-server"
        case .cliFailed(let details):
            return details
        case .lowConfidence(let details):
            return details
        case .captureIncomplete(let details):
            return details
        case .combined(let server, let cli):
            return "Server failed: \(server.localizedDescription). CLI fallback failed: \(cli.localizedDescription)"
        }
    }
}

final class TranscriptionManager: @unchecked Sendable {
    private static let vadActivationDurationMilliseconds = 15_000.0
    private static let vadMinSilenceDurationMilliseconds = 350
    private static let vadSpeechPadMilliseconds = 80
    private static let recentCaptureLimit = 12
    private static let inlinePlaceholderRegex = try! NSRegularExpression(
        pattern: #"[\[\(]\s*(?:BLANK[\s_-]*AUDIO|NO[\s_-]*SPEECH|NOSPEECH|SILENCE)\s*[\]\)]"#,
        options: [.caseInsensitive]
    )
    private static let repeatedSpacesRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let spaceBeforePunctuationRegex = try! NSRegularExpression(pattern: #"[ \t]+([,.;:!?])"#)

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
        let queueWaitMs = pending.enqueuedAt.timeIntervalSince(pending.capture.stoppedAt) * 1000.0
        let start = Date()
        let diskStatus = currentDiskStatus()
        let integrityAssessment = captureIntegrityAssessment(for: pending.capture)

        if integrityAssessment.requiresFailure {
            return captureIncompleteResult(
                for: pending,
                assessment: integrityAssessment,
                diskStatus: diskStatus
            )
        }

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
            case .text(let text, let diagnostic):
                let assessment = qualityAssessment(for: pending.capture, text: text)
                if assessment.requiresSecondPass {
                    return secondPassResult(
                        for: pending,
                        serverText: text,
                        serverDiagnostic: diagnostic,
                        serverAssessment: assessment,
                        start: start,
                        queueWaitMs: queueWaitMs,
                        diskStatus: diskStatus
                    )
                }

                return acceptedTextResult(
                    for: pending,
                    text: text,
                    diagnostic: diagnostic,
                    assessment: assessment,
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
                    case .text(let text, let diagnostic):
                        let assessment = qualityAssessment(for: pending.capture, text: text)
                        guard !assessment.requiresSecondPass else {
                            return lowConfidenceResult(
                                for: pending,
                                reason: assessment.reason ?? "low-confidence-transcript",
                                serverText: nil,
                                fallbackText: text,
                                assessment: assessment,
                                start: start,
                                queueWaitMs: queueWaitMs,
                                diskStatus: diskStatus
                            )
                        }

                        return acceptedTextResult(
                            for: pending,
                            text: text,
                            diagnostic: diagnostic,
                            assessment: assessment,
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
                case .text(let text, let diagnostic):
                    let assessment = qualityAssessment(for: pending.capture, text: text)
                    guard !assessment.requiresSecondPass else {
                        return lowConfidenceResult(
                            for: pending,
                            reason: assessment.reason ?? "low-confidence-transcript",
                            serverText: nil,
                            fallbackText: text,
                            assessment: assessment,
                            start: start,
                            queueWaitMs: queueWaitMs,
                            diskStatus: diskStatus
                        )
                    }

                    return acceptedTextResult(
                        for: pending,
                        text: text,
                        diagnostic: diagnostic,
                        assessment: assessment,
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

    private func acceptedTextResult(
        for pending: PendingTranscription,
        text: String,
        diagnostic: TranscriptDiagnostic?,
        assessment: TranscriptQualityAssessment,
        transcriptionMode: String,
        start: Date,
        queueWaitMs: Double
    ) -> SessionResultPayload {
        let salvagePath = diagnostic.flatMap { self.persistSalvage(for: pending, transcriptDiagnostic: $0) }
        persistRecentCapture(
            for: pending,
            transcript: text,
            transcriptionMode: transcriptionMode,
            assessment: assessment
        )

        return completedResult(
            for: pending.capture,
            text: text,
            salvagePath: salvagePath,
            transcriptionMode: transcriptionMode,
            start: start,
            queueWaitMs: queueWaitMs
        )
    }

    private func secondPassResult(
        for pending: PendingTranscription,
        serverText: String,
        serverDiagnostic: TranscriptDiagnostic?,
        serverAssessment: TranscriptQualityAssessment,
        start: Date,
        queueWaitMs: Double,
        diskStatus: DiskSpaceStatus?
    ) -> SessionResultPayload {
        fputs(
            "whisper-dictation-daemon: low-confidence server transcript; running CLI second pass (\(serverAssessment.reason ?? "unknown"))\n",
            stderr
        )

        do {
            switch try transcribeViaCLI(pending) {
            case .text(let cliText, let cliDiagnostic):
                let cliAssessment = qualityAssessment(for: pending.capture, text: cliText)
                guard !cliAssessment.requiresSecondPass else {
                    return lowConfidenceResult(
                        for: pending,
                        reason: cliAssessment.reason ?? serverAssessment.reason ?? "low-confidence-transcript",
                        serverText: serverText,
                        fallbackText: cliText,
                        assessment: cliAssessment,
                        start: start,
                        queueWaitMs: queueWaitMs,
                        diskStatus: diskStatus
                    )
                }

                return acceptedTextResult(
                    for: pending,
                    text: cliText,
                    diagnostic: cliDiagnostic ?? serverDiagnostic,
                    assessment: cliAssessment,
                    transcriptionMode: "cli-second-pass",
                    start: start,
                    queueWaitMs: queueWaitMs
                )
            case .noSpeech:
                return lowConfidenceResult(
                    for: pending,
                    reason: serverAssessment.reason ?? "low-confidence-transcript",
                    serverText: serverText,
                    fallbackText: nil,
                    assessment: serverAssessment,
                    start: start,
                    queueWaitMs: queueWaitMs,
                    diskStatus: diskStatus
                )
            }
        } catch {
            return lowConfidenceResult(
                for: pending,
                reason: serverAssessment.reason ?? "low-confidence-transcript",
                serverText: serverText,
                fallbackText: "CLI second pass failed: \(error.localizedDescription)",
                assessment: serverAssessment,
                start: start,
                queueWaitMs: queueWaitMs,
                diskStatus: diskStatus
            )
        }
    }

    private func lowConfidenceResult(
        for pending: PendingTranscription,
        reason: String,
        serverText: String?,
        fallbackText: String?,
        assessment: TranscriptQualityAssessment,
        start: Date,
        queueWaitMs: Double,
        diskStatus: DiskSpaceStatus?
    ) -> SessionResultPayload {
        let diagnostic = TranscriptDiagnostic(
            reason: reason,
            rawTranscript: """
            audio_duration_ms: \(Int(assessment.audioDurationMilliseconds))
            words_per_second: \(String(format: "%.2f", assessment.wordsPerSecond))
            characters_per_second: \(String(format: "%.2f", assessment.charactersPerSecond))

            server transcript:
            \(serverText ?? "(none)")

            fallback transcript:
            \(fallbackText ?? "(none)")
            """,
            cleanedTranscript: fallbackText ?? serverText ?? ""
        )

        return failedResult(
            for: pending,
            error: TranscriptionError.lowConfidence("Low-confidence dictation. Audio saved for review."),
            diskStatus: diskStatus,
            transcriptDiagnostic: diagnostic
        )
    }

    private func captureIncompleteResult(
        for pending: PendingTranscription,
        assessment: CaptureIntegrityAssessment,
        diskStatus: DiskSpaceStatus?
    ) -> SessionResultPayload {
        let diagnostic = TranscriptDiagnostic(
            reason: assessment.reason ?? "capture-duration-gap",
            rawTranscript: """
            capture_wall_clock_ms: \(Int(assessment.captureWallClockMilliseconds))
            captured_audio_ms: \(Int(assessment.capturedAudioMilliseconds))
            prebuffer_ms: \(Int(assessment.prebufferMilliseconds))
            active_audio_ms: \(Int(assessment.activeAudioMilliseconds))
            dropped_ms: \(Int(assessment.droppedMilliseconds))
            coverage_ratio: \(String(format: "%.2f", assessment.coverageRatio))
            """,
            cleanedTranscript: ""
        )

        return failedResult(
            for: pending,
            error: TranscriptionError.captureIncomplete("Audio capture dropped part of this dictation. Audio saved for review."),
            diskStatus: diskStatus,
            transcriptDiagnostic: diagnostic
        )
    }

    private func qualityAssessment(for capture: StoppedCapture, text: String) -> TranscriptQualityAssessment {
        TranscriptQuality.assess(
            text: text,
            audioDurationMilliseconds: audioDurationMilliseconds(for: capture)
        )
    }

    private func captureIntegrityAssessment(for capture: StoppedCapture) -> CaptureIntegrityAssessment {
        CaptureIntegrity.assess(
            capturedAudioMilliseconds: audioDurationMilliseconds(for: capture),
            prebufferMilliseconds: capture.prebufferMilliseconds,
            captureWallClockMilliseconds: capture.stoppedAt.timeIntervalSince(capture.startedAt) * 1000.0
        )
    }

    private func audioDurationMilliseconds(for capture: StoppedCapture) -> Double {
        Double(capture.samples.count) / 16.0
    }

    private func completedResult(
        for capture: StoppedCapture,
        text: String,
        salvagePath: String?,
        transcriptionMode: String,
        start: Date,
        queueWaitMs: Double
    ) -> SessionResultPayload {
        let integrity = captureIntegrityAssessment(for: capture)
        let metrics = SessionMetrics(
            sessionId: capture.sessionId,
            prebufferMilliseconds: capture.prebufferMilliseconds,
            audioDurationMilliseconds: integrity.capturedAudioMilliseconds,
            captureStartedAtISO8601: ISO8601DateFormatter().string(from: capture.startedAt),
            captureStoppedAtISO8601: ISO8601DateFormatter().string(from: capture.stoppedAt),
            captureWallClockMilliseconds: integrity.captureWallClockMilliseconds,
            activeAudioMilliseconds: integrity.activeAudioMilliseconds,
            captureDroppedMilliseconds: integrity.droppedMilliseconds,
            captureCoverageRatio: integrity.coverageRatio,
            transcriptionMode: transcriptionMode,
            transcriptionMilliseconds: Date().timeIntervalSince(start) * 1000.0,
            queueWaitMilliseconds: max(queueWaitMs, 0),
            completedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )

        return SessionResultPayload(
            sessionId: capture.sessionId,
            text: text,
            metrics: metrics,
            salvagePath: salvagePath,
            errorMessage: nil
        )
    }

    private func noSpeechResult(
        for capture: StoppedCapture,
        transcriptionMode: String,
        start: Date,
        queueWaitMs: Double
    ) -> SessionResultPayload {
        let integrity = captureIntegrityAssessment(for: capture)
        let metrics = SessionMetrics(
            sessionId: capture.sessionId,
            prebufferMilliseconds: capture.prebufferMilliseconds,
            audioDurationMilliseconds: integrity.capturedAudioMilliseconds,
            captureStartedAtISO8601: ISO8601DateFormatter().string(from: capture.startedAt),
            captureStoppedAtISO8601: ISO8601DateFormatter().string(from: capture.stoppedAt),
            captureWallClockMilliseconds: integrity.captureWallClockMilliseconds,
            activeAudioMilliseconds: integrity.activeAudioMilliseconds,
            captureDroppedMilliseconds: integrity.droppedMilliseconds,
            captureCoverageRatio: integrity.coverageRatio,
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
        diskStatus: DiskSpaceStatus?,
        transcriptDiagnostic: TranscriptDiagnostic? = nil
    ) -> SessionResultPayload {
        let integrity = captureIntegrityAssessment(for: pending.capture)
        let metrics = SessionMetrics(
            sessionId: pending.capture.sessionId,
            prebufferMilliseconds: pending.capture.prebufferMilliseconds,
            audioDurationMilliseconds: integrity.capturedAudioMilliseconds,
            captureStartedAtISO8601: ISO8601DateFormatter().string(from: pending.capture.startedAt),
            captureStoppedAtISO8601: ISO8601DateFormatter().string(from: pending.capture.stoppedAt),
            captureWallClockMilliseconds: integrity.captureWallClockMilliseconds,
            activeAudioMilliseconds: integrity.activeAudioMilliseconds,
            captureDroppedMilliseconds: integrity.droppedMilliseconds,
            captureCoverageRatio: integrity.coverageRatio,
            transcriptionMode: "failed",
            transcriptionMilliseconds: nil,
            queueWaitMilliseconds: nil,
            completedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )

        let salvagePath = persistSalvage(for: pending, transcriptDiagnostic: transcriptDiagnostic)
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
        if let vadModelPath = resolvedVADModelPath() {
            process.arguments?.append(contentsOf: ["-vm", vadModelPath])
        }

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
        let useVAD = shouldUseVAD(for: pending.capture)
        do {
            try ensureServerReady(timeout: 15.0)
            return try transcribeViaServer(
                wavData: pending.wavData,
                filename: pending.wavURL.lastPathComponent,
                useVAD: useVAD
            )
        } catch {
            try restartServer()
            return try transcribeViaServer(
                wavData: pending.wavData,
                filename: pending.wavURL.lastPathComponent,
                useVAD: useVAD
            )
        }
    }

    private func transcribeViaServer(wavData: Data, filename: String, useVAD: Bool) throws -> TranscriptOutcome {
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
        if useVAD {
            body.append(multipartField(name: "vad", value: "true", boundary: boundary))
            body.append(
                multipartField(
                    name: "vad_min_silence_duration_ms",
                    value: String(Self.vadMinSilenceDurationMilliseconds),
                    boundary: boundary
                )
            )
            body.append(
                multipartField(
                    name: "vad_speech_pad_ms",
                    value: String(Self.vadSpeechPadMilliseconds),
                    boundary: boundary
                )
            )
        }
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
        if shouldUseVAD(for: pending.capture), let vadModelPath = resolvedVADModelPath() {
            process.arguments?.append(contentsOf: [
                "--vad",
                "-vm", vadModelPath,
                "-vsd", String(Self.vadMinSilenceDurationMilliseconds),
                "-vp", String(Self.vadSpeechPadMilliseconds),
            ])
        }

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

        if isStandalonePlaceholderMarker(trimmed) {
            return .noSpeech
        }

        let stripped = stripPlaceholderArtifacts(from: trimmed)
        let normalized = stripped.hadPlaceholderArtifacts ? stripped.cleanedTranscript : trimmed

        guard !normalized.isEmpty else {
            return .noSpeech
        }

        guard normalized.rangeOfCharacter(from: .alphanumerics) != nil else {
            return .noSpeech
        }

        if stripped.hadPlaceholderArtifacts {
            return .text(
                normalized,
                TranscriptDiagnostic(
                    reason: "inline-placeholder-artifacts",
                    rawTranscript: trimmed,
                    cleanedTranscript: normalized
                )
            )
        }

        return .text(normalized, nil)
    }

    private func persistSalvage(
        for pending: PendingTranscription,
        transcriptDiagnostic: TranscriptDiagnostic? = nil
    ) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = "whisper-\(stamp)-\(pending.capture.sessionId)"
        let salvageURL = paths.salvageDirectoryURL.appendingPathComponent("\(baseName).wav")

        do {
            try pending.wavData.write(to: salvageURL, options: .atomic)
            if let transcriptDiagnostic {
                let diagnosticsURL = paths.salvageDirectoryURL.appendingPathComponent("\(baseName)-diagnostics.txt")
                let contents = """
                reason: \(transcriptDiagnostic.reason)
                session_id: \(pending.capture.sessionId)

                raw transcript:
                \(transcriptDiagnostic.rawTranscript)

                cleaned transcript:
                \(transcriptDiagnostic.cleanedTranscript)
                """
                try contents.write(to: diagnosticsURL, atomically: true, encoding: .utf8)
                fputs(
                    "whisper-dictation-daemon: \(transcriptDiagnostic.reason); saved diagnostics to \(diagnosticsURL.path)\n",
                    stderr
                )
            }
            return salvageURL.path
        } catch {
            fputs(
                "whisper-dictation-daemon: unable to save salvage audio: \(error.localizedDescription)\n",
                stderr
            )
            return nil
        }
    }

    private func persistRecentCapture(
        for pending: PendingTranscription,
        transcript: String,
        transcriptionMode: String,
        assessment: TranscriptQualityAssessment
    ) {
        let recentDirectory = paths.salvageDirectoryURL.appendingPathComponent("recent", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = "recent-\(stamp)-\(pending.capture.sessionId)"
        let wavURL = recentDirectory.appendingPathComponent("\(baseName).wav")
        let jsonURL = recentDirectory.appendingPathComponent("\(baseName).json")

        do {
            try FileManager.default.createDirectory(at: recentDirectory, withIntermediateDirectories: true)
            try pending.wavData.write(to: wavURL, options: .atomic)

            let qualityReason: Any = assessment.reason ?? NSNull()
            let integrity = captureIntegrityAssessment(for: pending.capture)
            let integrityReason: Any = integrity.reason ?? NSNull()
            let payload: [String: Any] = [
                "sessionId": pending.capture.sessionId,
                "completedAtISO8601": ISO8601DateFormatter().string(from: Date()),
                "transcriptionMode": transcriptionMode,
                "text": transcript,
                "metrics": [
                    "captureStartedAtISO8601": ISO8601DateFormatter().string(from: pending.capture.startedAt),
                    "captureStoppedAtISO8601": ISO8601DateFormatter().string(from: pending.capture.stoppedAt),
                    "audioDurationMilliseconds": integrity.capturedAudioMilliseconds,
                    "prebufferMilliseconds": pending.capture.prebufferMilliseconds,
                    "captureWallClockMilliseconds": integrity.captureWallClockMilliseconds,
                    "activeAudioMilliseconds": integrity.activeAudioMilliseconds,
                    "captureDroppedMilliseconds": integrity.droppedMilliseconds,
                    "captureCoverageRatio": integrity.coverageRatio,
                    "peakDecibels": jsonSafe(pending.capture.signalMetrics.peakDecibels),
                    "rmsDecibels": jsonSafe(pending.capture.signalMetrics.rmsDecibels),
                    "probablySilent": pending.capture.signalMetrics.probablySilent,
                ],
                "captureIntegrity": [
                    "requiresFailure": integrity.requiresFailure,
                    "reason": integrityReason,
                    "capturedAudioMilliseconds": integrity.capturedAudioMilliseconds,
                    "prebufferMilliseconds": integrity.prebufferMilliseconds,
                    "captureWallClockMilliseconds": integrity.captureWallClockMilliseconds,
                    "activeAudioMilliseconds": integrity.activeAudioMilliseconds,
                    "droppedMilliseconds": integrity.droppedMilliseconds,
                    "coverageRatio": integrity.coverageRatio,
                ],
                "quality": [
                    "requiresSecondPass": assessment.requiresSecondPass,
                    "reason": qualityReason,
                    "wordCount": assessment.wordCount,
                    "characterCount": assessment.characterCount,
                    "wordsPerSecond": assessment.wordsPerSecond,
                    "charactersPerSecond": assessment.charactersPerSecond,
                ],
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: jsonURL, options: .atomic)
            cleanupRecentCaptures(in: recentDirectory)
        } catch {
            fputs(
                "whisper-dictation-daemon: unable to save recent dictation proof: \(error.localizedDescription)\n",
                stderr
            )
        }
    }

    private func cleanupRecentCaptures(in directory: URL) {
        do {
            let wavs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "wav" }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }

            for staleWAV in wavs.dropFirst(Self.recentCaptureLimit) {
                let base = staleWAV.deletingPathExtension()
                try? FileManager.default.removeItem(at: staleWAV)
                try? FileManager.default.removeItem(at: base.appendingPathExtension("json"))
            }
        } catch {
            fputs(
                "whisper-dictation-daemon: unable to clean recent dictation proof: \(error.localizedDescription)\n",
                stderr
            )
        }
    }

    private func jsonSafe(_ value: Double) -> Any {
        value.isFinite ? value : NSNull()
    }

    private func currentDiskStatus() -> DiskSpaceStatus? {
        DiskSpaceMonitor.currentStatus(for: paths.tempDirectoryURL.path)
    }

    private func shouldAttemptCLIFallback(for capture: StoppedCapture, diskStatus: DiskSpaceStatus?) -> Bool {
        guard diskStatus?.criticalSpace != true else {
            return false
        }

        let audioDurationMilliseconds = audioDurationMilliseconds(for: capture)
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

    private func resolvedVADModelPath() -> String? {
        let fm = FileManager.default

        guard let configured = config.whisperVADModelPath, !configured.isEmpty else {
            return nil
        }

        if fm.isReadableFile(atPath: configured) {
            return configured
        }

        fputs("whisper-dictation-daemon: configured VAD model is not readable: \(configured)\n", stderr)
        return nil
    }

    private func shouldUseVAD(for capture: StoppedCapture) -> Bool {
        guard resolvedVADModelPath() != nil else {
            return false
        }

        return audioDurationMilliseconds(for: capture) >= Self.vadActivationDurationMilliseconds
    }

    private func isStandalonePlaceholderMarker(_ text: String) -> Bool {
        let marker = text
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        return [
            "[BLANKAUDIO]",
            "(BLANKAUDIO)",
            "[NOSPEECH]",
            "(NOSPEECH)",
            "[SILENCE]",
            "(SILENCE)",
        ].contains(marker)
    }

    private func stripPlaceholderArtifacts(from text: String) -> (cleanedTranscript: String, hadPlaceholderArtifacts: Bool) {
        let range = NSRange(text.startIndex..., in: text)
        let hadPlaceholderArtifacts = Self.inlinePlaceholderRegex.firstMatch(in: text, range: range) != nil
        guard hadPlaceholderArtifacts else {
            return (text, false)
        }

        let withoutMarkers = Self.inlinePlaceholderRegex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: " "
        )

        let lines = withoutMarkers
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { collapseSpaces(in: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let collapsed = lines.joined(separator: "\n")
        let cleaned = Self.spaceBeforePunctuationRegex.stringByReplacingMatches(
            in: collapsed,
            range: NSRange(collapsed.startIndex..., in: collapsed),
            withTemplate: "$1"
        )
        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    private func collapseSpaces(in text: String) -> String {
        Self.repeatedSpacesRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }
}
