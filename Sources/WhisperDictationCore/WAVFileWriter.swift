import Foundation

public enum WAVFileWriter {
    public static func mono16BitPCMData(
        samples: [Int16],
        sampleRate: Int
    ) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let chunkSize = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndian(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(littleEndian(UInt32(16)))
        data.append(littleEndian(UInt16(1)))
        data.append(littleEndian(channels))
        data.append(littleEndian(UInt32(sampleRate)))
        data.append(littleEndian(byteRate))
        data.append(littleEndian(blockAlign))
        data.append(littleEndian(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(littleEndian(dataSize))

        let pcmData = samples.withUnsafeBufferPointer { buffer in
            Data(buffer: UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
        }
        data.append(pcmData)

        return data
    }

    public static func writeMono16BitPCM(
        samples: [Int16],
        sampleRate: Int,
        to url: URL
    ) throws {
        try mono16BitPCMData(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
}
