import CoreAudio
import Foundation

public enum CoreAudioDeviceError: Error, LocalizedError {
    case missingDeviceList
    case preferredDeviceNotFound(String)
    case unableToReadDeviceName
    case unableToSetDefaultInput(String)

    public var errorDescription: String? {
        switch self {
        case .missingDeviceList:
            return "Unable to enumerate Core Audio devices."
        case .preferredDeviceNotFound(let name):
            return "Preferred input device '\(name)' was not found."
        case .unableToReadDeviceName:
            return "Unable to read the current default input device."
        case .unableToSetDefaultInput(let name):
            return "Unable to set '\(name)' as the default input device."
        }
    }
}

public enum CoreAudioDevice {
    public static func currentDefaultInputDeviceName() throws -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, let name = try deviceName(for: deviceID) else {
            throw CoreAudioDeviceError.unableToReadDeviceName
        }

        return name
    }

    public static func ensurePreferredInputDevice(
        named preferredName: String?,
        enforceAsDefault: Bool
    ) throws -> String {
        let current = try currentDefaultInputDeviceName()
        guard let preferredName, !preferredName.isEmpty else {
            return current
        }

        if current == preferredName || !enforceAsDefault {
            return current
        }

        try setDefaultInputDevice(named: preferredName)
        return try currentDefaultInputDeviceName()
    }

    private static func setDefaultInputDevice(named preferredName: String) throws {
        let devices = try inputDevices()
        guard let target = devices.first(where: { $0.name == preferredName }) else {
            throw CoreAudioDeviceError.preferredDeviceNotFound(preferredName)
        }

        var deviceID = target.id
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &deviceID
        )

        guard status == noErr else {
            throw CoreAudioDeviceError.unableToSetDefaultInput(preferredName)
        }
    }

    private static func inputDevices() throws -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr else {
            throw CoreAudioDeviceError.missingDeviceList
        }

        var ids = Array(repeating: AudioDeviceID(0), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        )
        guard dataStatus == noErr else {
            throw CoreAudioDeviceError.missingDeviceList
        }

        return try ids.compactMap { id in
            guard try hasInputStream(deviceID: id), let name = try deviceName(for: id) else {
                return nil
            }
            return (id: id, name: name)
        }
    }

    private static func hasInputStream(deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            return false
        }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferListPointer.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer)
        guard dataStatus == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func deviceName(for deviceID: AudioDeviceID) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        guard status == noErr else {
            throw CoreAudioDeviceError.unableToReadDeviceName
        }

        return cfName as String
    }
}
