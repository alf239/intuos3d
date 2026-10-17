// intuos3d: user-space driver for the Wacom Intuos 3 (PTZ-630, USB 056a:00b1) on macOS.
// Opens the tablet with IOHIDManager, switches it from boot-mouse mode to Intuos mode
// (feature report 2 = 2), parses pen/pad reports and posts tablet CGEvents.
//
//   intuos3d [--log]     --log (or "logReports": true in config.json) prints every HID report and parsed event.

import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

func log(_ s: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    print("\(t) \(s)")
    fflush(stdout)
}

let vendorID = 0x056a, productID = 0x00b1

let config = Config.load()
let logReports = config.logReports || CommandLine.arguments.contains("--log")
log("intuos3d starting (pid \(getpid())), config: \(Config.path.path)")

// Permissions: posting events needs Accessibility; opening a mouse-class HID device needs Input Monitoring.
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    log("Accessibility NOT granted: System Settings > Privacy & Security > Accessibility. Posted events will be dropped until granted.")
}
if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
    log("Input Monitoring NOT granted: System Settings > Privacy & Security > Input Monitoring. The tablet cannot be opened until granted.")
}

var parser = Intuos3Parser()
let output = EventOutput(config: config)

func setIntuosMode(_ device: IOHIDDevice) {
    // Linux wacom_set_device_mode for Intuos: feature report 2, value 2. Read back to confirm.
    let req: [UInt8] = [0x02, 0x02]
    let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 2, req, req.count)
    var back = [UInt8](repeating: 0, count: 2)
    var len = CFIndex(back.count)
    let g = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 2, &back, &len)
    log(String(format: "mode switch: set=0x%08x get=0x%08x value=[%02x %02x]%@", r, g, back[0], back[1],
               (r == kIOReturnSuccess && back[1] == 2) ? " -> Intuos mode" : " -> FAILED"))
}

var opened = false

let onMatch: IOHIDDeviceCallback = { _, _, _, device in
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    let len = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
    log("tablet attached: \(name), max input report \(len) bytes")
    parser.reset()
    if opened { setIntuosMode(device) }
}

let onRemove: IOHIDDeviceCallback = { _, _, _, _ in
    log("tablet detached")
    if parser.inProximity { output.handle(.proximityOut) }
    parser.reset()
}

let onReport: IOHIDReportCallback = { _, result, _, _, reportID, report, length in
    guard result == kIOReturnSuccess, length > 0 else { return }
    var bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
    if bytes.count == 9 { bytes.insert(UInt8(reportID), at: 0) }  // in case the ID byte is not included
    if logReports { log("report " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")) }
    guard let ev = parser.parse(bytes) else { return }
    if logReports { log("  -> \(ev)") }
    output.handle(ev)
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(manager, onMatch, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, onRemove, nil)
IOHIDManagerRegisterInputReportCallback(manager, onReport, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult == kIOReturnSuccess {
    opened = true
    for d in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] { setIntuosMode(d) }
} else {
    log(String(format: "IOHIDManagerOpen failed: 0x%08x%@", openResult,
               openResult == kIOReturnNotPermitted ? " (Input Monitoring permission missing)" : ""))
}

// Permissions can be granted while we run. Input Monitoring needs a fresh open, so exit and let
// launchd (KeepAlive) restart us; Accessibility takes effect immediately.
var axGranted = AXIsProcessTrusted()
Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
    if !opened && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
        log("Input Monitoring granted; restarting to open the tablet")
        exit(0)
    }
    if !axGranted && AXIsProcessTrusted() { axGranted = true; log("Accessibility granted") }
}

// Re-map when displays change (resolution, arrangement).
CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
    if flags.contains(.setMainFlag) || flags.contains(.desktopShapeChangedFlag) { output.updateGeometry() }
}, nil)

signal(SIGTERM) { _ in
    output.releaseAllButtons()
    exit(0)
}

log("waiting for tablet reports (use --log to print them)")
CFRunLoopRun()
