// eventmon: logs the tablet NSEvents AppKit delivers system-wide (global monitor), to check what a
// user-space driver's CGEvents look like to apps. Build: swiftc -O eventmon.swift -o eventmon
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var moves = 0

func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }

NSEvent.addGlobalMonitorForEvents(matching: [.tabletProximity, .tabletPoint, .mouseMoved, .leftMouseDown,
                                             .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                             .otherMouseDown, .otherMouseUp]) { e in
    var line: String?
    if e.type == .tabletProximity || e.subtype == .tabletProximity {
        line = "PROXIMITY type=\(e.type.rawValue) enter=\(e.isEnteringProximity) pointingDeviceType=\(e.pointingDeviceType.rawValue) (1 pen, 2 cursor, 3 eraser) vendorPointerType=0x\(String(e.vendorPointingDeviceType, radix: 16)) deviceID=\(e.deviceID) uniqueID=\(e.uniqueID) tabletID=\(e.tabletID) capability=0x\(String(e.capabilityMask, radix: 16))"
    } else if e.subtype == .tabletPoint {
        let isMove = e.type == .mouseMoved || e.type == .leftMouseDragged
        moves += isMove ? 1 : 0
        if !isMove || moves % 25 == 0 {
            line = "POINT type=\(e.type.rawValue) pressure=\(String(format: "%.3f", e.pressure)) tilt=(\(String(format: "%.2f", e.tilt.x)),\(String(format: "%.2f", e.tilt.y))) buttons=\(e.buttonMask.rawValue) deviceID=\(e.deviceID) abs=(\(e.absoluteX),\(e.absoluteY),\(e.absoluteZ))"
        }
    }
    if let l = line { print(stamp(), l); fflush(stdout) }
}
print(stamp(), "eventmon running"); fflush(stdout)
app.run()
