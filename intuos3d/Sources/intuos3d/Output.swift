// Turns TabletEvents into CGEvents: tablet proximity events plus mouse events carrying the
// tablet-point subtype (pressure, tilt, buttons), which is what AppKit/Qt apps read pressure from.

import CoreGraphics
import Foundation

final class EventOutput {
    let config: Config
    /// Arbitrary but must be identical on proximity and point events: Qt/AppKit key tablet state on it.
    private let deviceID: Int64 = 0x0B1
    private let capabilityMask: Int64 = 0x0002 | 0x0004 | 0x0040 | 0x0080 | 0x0100 | 0x0400 // X Y buttons tiltX tiltY pressure

    private var screen = CGRect.zero
    private var tabletRect = CGRect.zero  // active area in tablet units
    private var heldButtons = 0           // bit n = CGMouseButton n currently down
    private var lastPoint = CGPoint.zero
    private var pointerType: Int64 = 1    // 1 pen, 2 cursor, 3 eraser
    private var heldKeys = 0
    private var stripPos = [0, 0]
    private let buttons: [CGMouseButton] = [.left, .right, .center]

    init(config: Config) {
        self.config = config
        updateGeometry()
    }

    func updateGeometry() {
        screen = CGDisplayBounds(CGMainDisplayID())
        let tw = CGFloat(Intuos3Parser.maxX), th = CGFloat(Intuos3Parser.maxY)
        if config.mapping == "stretch" {
            tabletRect = CGRect(x: 0, y: 0, width: tw, height: th)
        } else {  // largest centred sub-area of the tablet with the screen's aspect ratio
            let aspect = screen.width / screen.height
            var w = tw, h = tw / aspect
            if h > th { h = th; w = th * aspect }
            tabletRect = CGRect(x: (tw - w) / 2, y: (th - h) / 2, width: w, height: h)
        }
        log("mapping tablet area \(Int(tabletRect.minX)),\(Int(tabletRect.minY)) \(Int(tabletRect.width))x\(Int(tabletRect.height)) -> display \(Int(screen.width))x\(Int(screen.height))")
    }

    private func toScreen(_ x: Int, _ y: Int) -> CGPoint {
        let fx = min(max((CGFloat(x) - tabletRect.minX) / tabletRect.width, 0), 1)
        let fy = min(max((CGFloat(y) - tabletRect.minY) / tabletRect.height, 0), 1)
        return CGPoint(x: screen.minX + fx * (screen.width - 1), y: screen.minY + fy * (screen.height - 1))
    }

    func handle(_ ev: TabletEvent) {
        switch ev {
        case .proximityIn(let toolId, let serial, let kind):
            pointerType = kind == .eraser ? 3 : (kind == .mouse ? 2 : 1)
            postProximity(enter: true, toolId: toolId, serial: serial)
        case .proximityOut:
            releaseAllButtons()
            postProximity(enter: false, toolId: 0, serial: 0)
        case .pen(let s):
            var wanted = 0
            if s.buttons & 1 != 0 { wanted |= 1 << CGMouseButton.left.rawValue }
            if s.buttons & 2 != 0, let b = config.penButton1.cgButton { wanted |= 1 << b.rawValue }
            if s.buttons & 4 != 0, let b = config.penButton2.cgButton { wanted |= 1 << b.rawValue }
            let p = TabletPoint(
                screen: toScreen(s.x, s.y), rawX: s.x, rawY: s.y, z: s.distance, buttons: s.buttons,
                pressure: pow(Double(s.pressure) / Double(Intuos3Parser.maxPressure), config.pressureGamma),
                tiltX: Double(s.tiltX) / 64, tiltY: Double(s.tiltY) / 64)
            postPointer(p, wanted: wanted)
        case .mouse(let x, let y, let b, let wheel):
            var wanted = 0
            if b & 1 != 0 { wanted |= 1 << CGMouseButton.left.rawValue }
            if b & 2 != 0 { wanted |= 1 << CGMouseButton.right.rawValue }
            if b & 4 != 0 { wanted |= 1 << CGMouseButton.center.rawValue }
            postPointer(TabletPoint(screen: toScreen(x, y), rawX: x, rawY: y, z: 0, buttons: b,
                                    pressure: 0, tiltX: 0, tiltY: 0), wanted: wanted)
            if wheel != 0 { KeyAction("scroll:\(wheel)").post(down: true) }
        case .pad(let keys, let left, let right):
            handlePad(keys: keys, strips: [left, right])
        }
    }

    func releaseAllButtons() {
        guard heldButtons != 0 else { return }
        let p = TabletPoint(screen: lastPoint, rawX: 0, rawY: 0, z: 0, buttons: 0, pressure: 0, tiltX: 0, tiltY: 0)
        postPointer(p, wanted: 0)
    }

    // MARK: - CGEvent construction

    struct TabletPoint {
        var screen: CGPoint
        var rawX: Int, rawY: Int, z: Int
        var buttons: Int
        var pressure: Double, tiltX: Double, tiltY: Double
    }

    private func postProximity(enter: Bool, toolId: Int, serial: UInt64) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .tabletProximity
        e.location = lastPoint
        e.setIntegerValueField(.tabletProximityEventVendorID, value: 0x056a)
        e.setIntegerValueField(.tabletProximityEventTabletID, value: 0x00b1)
        e.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: Int64(toolId))
        e.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: Int64(serial & 0x7fff_ffff))
        e.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: Int64(serial & 0x7fff_ffff))
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: pointerType)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        e.post(tap: .cghidEventTap)
    }

    private func postPointer(_ p: TabletPoint, wanted: Int) {
        lastPoint = p.screen
        var transitioned = false
        for b in buttons {
            let bit = 1 << Int(b.rawValue)
            let was = heldButtons & bit != 0, want = wanted & bit != 0
            guard was != want else { continue }
            post(type: mouseType(b, down: want, drag: false), button: b, p)
            if want { heldButtons |= bit } else { heldButtons &= ~bit }
            transitioned = true
        }
        if transitioned { return }
        if let held = buttons.first(where: { heldButtons & (1 << Int($0.rawValue)) != 0 }) {
            post(type: mouseType(held, down: true, drag: true), button: held, p)
        } else {
            post(type: .mouseMoved, button: .left, p)
        }
    }

    private func mouseType(_ b: CGMouseButton, down: Bool, drag: Bool) -> CGEventType {
        switch b {
        case .left: return drag ? .leftMouseDragged : (down ? .leftMouseDown : .leftMouseUp)
        case .right: return drag ? .rightMouseDragged : (down ? .rightMouseDown : .rightMouseUp)
        default: return drag ? .otherMouseDragged : (down ? .otherMouseDown : .otherMouseUp)
        }
    }

    private func post(type: CGEventType, button: CGMouseButton, _ p: TabletPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p.screen, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventSubtype, value: 1)  // kCGEventMouseSubtypeTabletPoint
        e.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
        e.setDoubleValueField(.mouseEventPressure, value: p.pressure)
        e.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(p.rawX))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(p.rawY))
        e.setIntegerValueField(.tabletEventPointZ, value: Int64(p.z))
        e.setIntegerValueField(.tabletEventPointButtons, value: Int64(p.buttons))
        e.setDoubleValueField(.tabletEventPointPressure, value: p.pressure)
        e.setDoubleValueField(.tabletEventTiltX, value: p.tiltX)
        e.setDoubleValueField(.tabletEventTiltY, value: p.tiltY)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - ExpressKeys and strips

    private func handlePad(keys: Int, strips: [Int]) {
        let changed = keys ^ heldKeys
        for i in 0..<8 where changed & (1 << i) != 0 && i < config.expressKeys.count {
            KeyAction(config.expressKeys[i]).post(down: keys & (1 << i) != 0)
        }
        heldKeys = keys
        for s in 0..<2 {
            let pos = strips[s], prev = stripPos[s]
            stripPos[s] = pos
            guard pos != 0, prev != 0, pos != prev else { continue }  // only finger motion, not touch/lift
            let actions = s == 0 ? config.leftStrip : config.rightStrip
            let spec = pos > prev ? actions.first : actions.dropFirst().first
            KeyAction(spec ?? "none").tap(times: abs(pos - prev))
        }
    }
}
