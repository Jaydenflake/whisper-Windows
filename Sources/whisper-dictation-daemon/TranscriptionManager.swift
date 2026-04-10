import Foundation
import WhisperDictationCore

private struct PendingTranscription {
    let capture: StoppedCapture
    let wavURL: URL
    let enqueuedAt: Date
}

private enum ServerState: String {
    case stopped
    case starting
    case ready
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
            do {
                try WAVFileWriter.writeMono16BitPCM(samples: capture.samples, sampleRate: 16_000, to: wavURL)
                let pending = PendingTranscription(capture: capture, wavURL: wavURL, enqueuedAt: Date())
                self.pending.append(pending)
                self.processNextIfNeeded()
            } catch {
                let result = self.failedResult(for: capture, salvageSource: wavURL, error: error)
                self.onCompleted(result)
            }
        }
    }

    func pendingCount() -> Int {
        queue.sync {
            pending.count + (processing ? 1 : 0)
        }
    }

    func currentServerState() -> String {
        queue.sync {
            return serverState.rawValue
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
        let queueWaitMs = pending.enqueuedAt.timeIntervalSince(pending.capture.startedAt.addingTimeInterval(Double(pending.capture.samples.count) / 16_000.0)) * 1000.0
        let start = Date()

        do {
            try ensureServerReady(timeout: 15.0)
            let text = try transcribeViaServer(wavURL: pending.wavURL)
            try? FileManager.default.removeItem(at: pending.wavURL)

            let metrics = SessionMetrics(
                sessionId: pending.capture.sessionId,
                prebufferMilliseconds: pending.capture.prebufferMilliseconds,
                audioDurationMilliseconds: Double(pending.capture.samples.count) / 16.0,
                transcriptionMode: "server",
                transcriptionMilliseconds: Date().timeIntervalSince(start) * 1000.0,
                queueWaitMilliseconds: max(queueWaitMs, 0),
                completedAtISO8601: ISO8601DateFormatter().string(from: Date())
            )

            return SessionResultPayload(
                sessionId: pending.capture.sessionId,
                text: text,
                metrics: metrics,
                salvagePath: nil
            )
        } catch {
            do {
                let text = try transcribeViaCLI(wavURL: pending.wavURL)
                try? FileManager.default.removeItem(at: pending.wavURL)

                let metrics = SessionMetrics(
                    sessionId: pending.capture.sessionId,
                    prebufferMilliseconds: pending.capture.prebufferMilliseconds,
                    audioDurationMilliseconds: Double(pending.capture.samples.count) / 16.0,
                    transcriptionMode: "cli",
                    transcriptionMilliseconds: Date().timeIntervalSince(start) * 1000.0,
                    queueWaitMilliseconds: max(queueWaitMs, 0),
                    completedAtISO8601: ISO8601DateFormatter().string(from: Date())
                )

                return SessionResultPayload(
                    sessionId: pending.capture.sessionId,
                    text: text,
                    metrics: metrics,
                    salvagePath: nil
                )
            } catch {
                return failedResult(for: pending.capture, salvageSource: pending.wavURL, error: error)
            }
        }
    }

    private func failedResult(for capture: StoppedCapture, salvageSource: URL, error: Error) -> SessionResultPayload {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let salvageURL = paths.salvageDirectoryURL.appendingPathComponent("whisper-\(stamp)-\(capture.sessionId).wav")
        if fm.fileExists(atPath: salvageSource.path) {
            try? fm.copyItem(at: salvageSource, to: salvageURL)
            try? fm.removeItem(at: salvageSource)
        }

        let metrics = SessionMetrics(
            sessionId: capture.sessionId,
            prebufferMilliseconds: capture.prebufferMilliseconds,
            audioDurationMilliseconds: Double(capture.samples.count) / 16.0,
            transcriptionMode: "failed",
            transcriptionMilliseconds: nil,
            queueWaitMilliseconds: nil,
            completedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )

        return SessionResultPayload(
            sessionId: capture.sessionId,
            text: "",
            metrics: metrics,
            salvagePath: salvageURL.path + " (" + error.localizedDescription + ")"
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

        throw NSError(domain: "WhisperDictation", code: 2, userInfo: [NSLocalizedDescriptionKey: "whisper-server did not become ready"])
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

    private func transcribeViaServer(wavURL: URL) throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "http://\(config.whisperServerHost):\(config.whisperServerPort)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: wavURL)
        var body = Data()
        body.append(multipartField(name: "response_format", value: "json", boundary: boundary))
        body.append(multipartField(name: "no_timestamps", value: "true", boundary: boundary))
        body.append(multipartField(name: "temperature", value: "0.0", boundary: boundary))
        body.append(multipartFile(name: "file", filename: wavURL.lastPathComponent, mimeType: "audio/wav", data: fileData, boundary: boundary))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        URLSession.shared.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let responseError {
            throw responseError
        }
        guard let responseData else {
            throw NSError(domain: "WhisperDictation", code: 3, userInfo: [NSLocalizedDescriptionKey: "No response body from whisper-server"])
        }

        let payload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        let text = (payload?["text"] as? String) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeViaCLI(wavURL: URL) throws -> String {
        let outBase = paths.tempDirectoryURL.appendingPathComponent("cli-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperCliBinary)
        process.arguments = [
            "-m", config.whisperModelPath,
            "-f", wavURL.path,
            "-nt",
            "-np",
            "--output-txt",
            "--output-file", outBase.path,
            "-t", String(config.whisperThreads),
        ]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WhisperDictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "whisper-cli failed"])
        }

        let txtURL = outBase.appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: txtURL)
        }
        let text = try String(contentsOf: txtURL, encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isServerHealthySync() -> Bool {
        guard let url = URL(string: "http://\(config.whisperServerHost):\(config.whisperServerPort)/") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 0.25
        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false

        URLSession.shared.dataTask(with: request) { _, response, error in
            if error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200 {
                healthy = true
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + .milliseconds(300))
        return healthy
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
}
