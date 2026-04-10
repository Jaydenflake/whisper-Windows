import Darwin
import Foundation

public enum JSONSocketError: Error, LocalizedError {
    case socketCreationFailed
    case bindFailed(String)
    case listenFailed
    case connectFailed(String)
    case invalidResponse
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Unable to create the control socket."
        case .bindFailed(let message):
            return "Unable to bind the control socket: \(message)"
        case .listenFailed:
            return "Unable to listen on the control socket."
        case .connectFailed(let message):
            return "Unable to connect to the control socket: \(message)"
        case .invalidResponse:
            return "The control socket returned an invalid response."
        case .encodingFailed:
            return "Unable to encode the control request."
        case .decodingFailed:
            return "Unable to decode the control response."
        }
    }
}

public final class JSONSocketServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let handler: @Sendable (ControlRequest) -> ControlResponse
    private let acceptQueue = DispatchQueue(label: "whisper.dictation.control.accept", qos: .userInitiated)
    private let handlerQueue = DispatchQueue(label: "whisper.dictation.control.handler", qos: .userInitiated, attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var running = false

    public init(
        host: String,
        port: Int,
        handler: @escaping @Sendable (ControlRequest) -> ControlResponse
    ) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    public func start() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw JSONSocketError.socketCreationFailed
        }

        var reuse = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr(host))

        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindStatus == 0 else {
            let message = String(cString: strerror(errno))
            close(socketFD)
            throw JSONSocketError.bindFailed(message)
        }

        guard listen(socketFD, 16) == 0 else {
            close(socketFD)
            throw JSONSocketError.listenFailed
        }

        listenFD = socketFD
        running = true

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop() {
        while running {
            var clientAddress = sockaddr()
            var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(listenFD, &clientAddress, &clientLength)

            if clientFD < 0 {
                if errno == EINTR || errno == EAGAIN {
                    continue
                }
                if !running {
                    break
                }
                continue
            }

            handlerQueue.async { [weak self] in
                self?.handleClient(fd: clientFD)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }

        guard
            let requestData = readLine(from: fd),
            let request = try? JSONDecoder().decode(ControlRequest.self, from: requestData)
        else {
            let response = ControlResponse(ok: false, error: JSONSocketError.decodingFailed.localizedDescription)
            _ = writeResponse(response, to: fd)
            return
        }

        let response = handler(request)
        _ = writeResponse(response, to: fd)
    }

    private func readLine(from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 {
                break
            }

            data.append(buffer, count: count)
            if data.last == 0x0A {
                break
            }
        }

        guard !data.isEmpty else {
            return nil
        }

        if data.last == 0x0A {
            data.removeLast()
        }

        return data
    }

    private func writeResponse(_ response: ControlResponse, to fd: Int32) -> Bool {
        guard let encoded = try? JSONEncoder().encode(response) else {
            return false
        }

        var payload = encoded
        payload.append(0x0A)

        return payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return false
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                if written <= 0 {
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

public enum JSONSocketClient {
    public static func send(
        _ request: ControlRequest,
        host: String,
        port: Int,
        timeoutMilliseconds: Int = 1200
    ) throws -> ControlResponse {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw JSONSocketError.socketCreationFailed
        }
        defer { close(socketFD) }

        var timeout = timeval(
            tv_sec: Int(timeoutMilliseconds / 1000),
            tv_usec: Int32((timeoutMilliseconds % 1000) * 1000)
        )
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr(host))

        let connectStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard connectStatus == 0 else {
            let message = String(cString: strerror(errno))
            throw JSONSocketError.connectFailed(message)
        }

        guard var payload = try? JSONEncoder().encode(request) else {
            throw JSONSocketError.encodingFailed
        }
        payload.append(0x0A)

        let sendSucceeded = payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return false
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.send(socketFD, base.advanced(by: offset), bytes.count - offset, 0)
                if written <= 0 {
                    return false
                }
                offset += written
            }
            return true
        }
        guard sendSucceeded else {
            throw JSONSocketError.connectFailed("Send failed")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(socketFD, &buffer, buffer.count, 0)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
            if data.last == 0x0A {
                break
            }
        }

        guard !data.isEmpty else {
            throw JSONSocketError.invalidResponse
        }
        if data.last == 0x0A {
            data.removeLast()
        }

        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: data) else {
            throw JSONSocketError.decodingFailed
        }

        return response
    }
}
