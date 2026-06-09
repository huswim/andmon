import Foundation
import CoreGraphics
import VirtualDisplayBridge

final class VirtualDisplay: @unchecked Sendable {
    private var raw: OpaquePointer?
    let displayID: CGDirectDisplayID

    init(refreshRate: Int) throws {
        var error: UnsafeMutableRawPointer?
        guard let raw = AndmonVirtualDisplayCreate(Int32(refreshRate), &error) else {
            throw BridgeError.take(error, fallback: "Unable to create virtual display")
        }
        self.raw = raw
        displayID = AndmonVirtualDisplayID(raw)
    }

    func close() {
        if let raw {
            self.raw = nil
            AndmonVirtualDisplayRelease(raw)
        }
    }

    deinit { close() }
}

enum BridgeError {
    static func take(_ pointer: UnsafeMutableRawPointer?, fallback: String) -> NSError {
        guard let pointer else {
            return NSError(domain: "dev.andmon.bridge", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: fallback])
        }
        return Unmanaged<NSError>.fromOpaque(pointer).takeRetainedValue()
    }
}
