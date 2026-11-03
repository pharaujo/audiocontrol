import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let what: String
    public var description: String { "\(what) failed: \(status) (\(fourCC(status)))" }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return String(status)
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// Thin typed wrappers over the AudioObject property API.
enum CA {
    static func has(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(id, &a)
    }

    static func isSettable(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var settable: DarwinBoolean = false
        let st = AudioObjectIsPropertySettable(id, &a, &settable)
        return st == noErr && settable.boolValue
    }

    static func dataSize(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress,
                         qualifier: (size: UInt32, data: UnsafeRawPointer?) = (0, nil)) throws -> UInt32 {
        var a = addr
        var size: UInt32 = 0
        let st = AudioObjectGetPropertyDataSize(id, &a, qualifier.size, qualifier.data, &size)
        guard st == noErr else { throw CoreAudioError(status: st, what: "GetPropertyDataSize \(fourCC(Int32(bitPattern: addr.mSelector)))") }
        return size
    }

    /// Plain-old-data property (UInt32, Float32, AudioObjectID, pid_t, ASBD...).
    static func get<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, as _: T.Type,
                       qualifier: (size: UInt32, data: UnsafeRawPointer?) = (0, nil)) throws -> T {
        var a = addr
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        let st = AudioObjectGetPropertyData(id, &a, qualifier.size, qualifier.data, &size, ptr)
        guard st == noErr else { throw CoreAudioError(status: st, what: "GetPropertyData \(fourCC(Int32(bitPattern: addr.mSelector)))") }
        return ptr.pointee
    }

    static func getArray<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, of _: T.Type) throws -> [T] {
        var a = addr
        var size = try dataSize(id, addr)
        let count = Int(size) / MemoryLayout<T>.stride
        if count == 0 { return [] }
        let buf = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buf.deallocate() }
        let st = AudioObjectGetPropertyData(id, &a, 0, nil, &size, buf)
        guard st == noErr else { throw CoreAudioError(status: st, what: "GetPropertyData[] \(fourCC(Int32(bitPattern: addr.mSelector)))") }
        return Array(UnsafeBufferPointer(start: buf, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> String {
        var a = addr
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>? = nil
        let st = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value)
        guard st == noErr else { throw CoreAudioError(status: st, what: "GetPropertyData(str) \(fourCC(Int32(bitPattern: addr.mSelector)))") }
        guard let v = value else { return "" }
        return v.takeRetainedValue() as String
    }

    static func set<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) throws {
        var a = addr
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        ptr.initialize(to: value)
        defer { ptr.deinitialize(count: 1); ptr.deallocate() }
        let st = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), ptr)
        guard st == noErr else { throw CoreAudioError(status: st, what: "SetPropertyData \(fourCC(Int32(bitPattern: addr.mSelector)))") }
    }

    /// Property listener that removes itself on deinit. The block is invoked
    /// on `queue`.
    final class Listener: @unchecked Sendable {
        private let objectID: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private var installed = false

        init?(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, queue: DispatchQueue,
              _ handler: @escaping @Sendable () -> Void) {
            objectID = id
            address = addr
            self.queue = queue
            block = { _, _ in handler() }
            let st = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
            guard st == noErr else { return nil }
            installed = true
        }

        deinit {
            if installed {
                AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
            }
        }
    }

    // MARK: System / device conveniences

    static func defaultOutputDeviceID() -> AudioObjectID? {
        let id = try? get(AudioObjectID(kAudioObjectSystemObject),
                          .init(kAudioHardwarePropertyDefaultOutputDevice), as: AudioObjectID.self)
        return (id ?? kAudioObjectUnknown) == kAudioObjectUnknown ? nil : id
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        (try? getArray(AudioObjectID(kAudioObjectSystemObject), .init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
    }

    static func deviceUID(_ id: AudioObjectID) -> String? {
        try? getString(id, .init(kAudioDevicePropertyDeviceUID))
    }

    static func objectName(_ id: AudioObjectID) -> String? {
        try? getString(id, .init(kAudioObjectPropertyName))
    }

    static func transportType(_ id: AudioObjectID) -> UInt32? {
        try? get(id, .init(kAudioDevicePropertyTransportType), as: UInt32.self)
    }

    static func isBluetooth(_ id: AudioObjectID) -> Bool {
        guard let t = transportType(id) else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        ((try? getArray(id, .init(kAudioDevicePropertyStreams, scope: scope), of: AudioObjectID.self)) ?? []).count
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        try? get(id, .init(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
    }
}
