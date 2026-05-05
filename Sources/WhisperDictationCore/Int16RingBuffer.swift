import Foundation

public final class Int16RingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Int16]
    private var writeIndex = 0
    private var count = 0
    private let lock = NSLock()

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        self.storage = Array(repeating: 0, count: self.capacity)
    }

    public func append(_ samples: UnsafeBufferPointer<Int16>) {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            count = min(count + 1, capacity)
        }
    }

    public func snapshot() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }

        guard count > 0 else {
            return []
        }

        if count < capacity {
            return Array(storage[0..<count])
        }

        return Array(storage[writeIndex..<capacity] + storage[0..<writeIndex])
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        storage = Array(repeating: 0, count: capacity)
        writeIndex = 0
        count = 0
    }

    public var availableMilliseconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(count) / 16.0
    }
}
