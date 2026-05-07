import Foundation

public final class SessionResultBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var results = [SessionResultPayload]()

    public init() {}

    public func append(_ result: SessionResultPayload) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }

    public func popNext(sessionId: String? = nil) -> SessionResultPayload? {
        lock.lock()
        defer { lock.unlock() }

        guard !results.isEmpty else {
            return nil
        }

        guard let sessionId, !sessionId.isEmpty else {
            return results.removeFirst()
        }

        guard let index = results.firstIndex(where: { $0.sessionId == sessionId }) else {
            return nil
        }

        let result = results[index]
        results.removeSubrange(...index)
        return result
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return results.count
    }
}
