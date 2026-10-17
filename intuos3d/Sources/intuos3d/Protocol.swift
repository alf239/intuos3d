// Intuos 3 (PTZ-x30) USB report parser.
// Reference: Linux drivers/hid/wacom_wac.c, INTUOS3 paths (wacom_intuos_inout,
// wacom_intuos_general, wacom_intuos_pad). All reports are 10 bytes, byte 0 = report ID.

import Foundation

enum ToolKind { case pen, eraser, mouse, unknown }

struct PenState {
    var x = 0, y = 0, distance = 0
    var pressure = 0          // 0...1023
    var tiltX = 0, tiltY = 0  // -64...63
    var buttons = 0           // bit0 tip, bit1 side button 1, bit2 side button 2
}

enum TabletEvent {
    case proximityIn(toolId: Int, serial: UInt64, kind: ToolKind)
    case proximityOut
    case pen(PenState)
    case mouse(x: Int, y: Int, buttons: Int, wheel: Int)   // buttons: 1 left, 2 right, 4 middle, 8/16 side
    case pad(buttons: Int, leftStrip: Int, rightStrip: Int) // strips: 0 = no finger, else 1...13 position
}

struct Intuos3Parser {
    static let maxX = 40640, maxY = 30480, maxPressure = 1023, maxDistance = 63
    static let penReport: UInt8 = 0x02, padReport: UInt8 = 0x0C

    private(set) var toolId = 0
    private(set) var serial: UInt64 = 0
    private(set) var kind: ToolKind = .unknown
    var inProximity: Bool { toolId != 0 }

    static func toolKind(_ id: Int) -> ToolKind {
        switch id {
        case 0x017, 0x806, 0x007, 0x09c, 0x094: return .mouse  // 2D / 4D mice
        case 0x096, 0x097, 0x006: return .mouse                // lens cursors
        default: return (id & 0x0008) != 0 ? .eraser : .pen
        }
    }

    mutating func reset() { toolId = 0; serial = 0; kind = .unknown }

    mutating func parse(_ d: [UInt8]) -> TabletEvent? {
        guard d.count >= 10 else { return nil }
        switch d[0] {
        case Self.padReport: return parsePad(d)
        case Self.penReport: return parsePen(d)
        default: return nil
        }
    }

    private mutating func parsePen(_ d: [UInt8]) -> TabletEvent? {
        let b1 = Int(d[1])
        if b1 & 0xfc == 0xc0 {  // proximity enter: tool id + serial
            toolId = (Int(d[2]) << 4) | (Int(d[3]) >> 4) | ((Int(d[7]) & 0x0f) << 16) | ((Int(d[8]) & 0xf0) << 8)
            serial = (UInt64(d[3] & 0x0f) << 28) + (UInt64(d[4]) << 20) + (UInt64(d[5]) << 12)
                + (UInt64(d[6]) << 4) + UInt64(d[7] >> 4)
            kind = Self.toolKind(toolId)
            return .proximityIn(toolId: toolId, serial: serial, kind: kind)
        }
        if b1 & 0xfe == 0x80 {  // proximity exit
            guard toolId != 0 else { return nil }
            reset()
            return .proximityOut
        }
        if b1 & 0xfe == 0x20 { return nil }  // "in range" heartbeat, carries no data
        guard toolId != 0 else { return nil } // never saw the enter report; ignore until we do

        let type = (b1 >> 1) & 0x0f
        let x = (Int(d[2]) << 9) | (Int(d[3]) << 1) | ((Int(d[9]) >> 1) & 1)
        let y = (Int(d[4]) << 9) | (Int(d[5]) << 1) | (Int(d[9]) & 1)
        let distance = Int(d[9]) >> 2

        switch type {
        case 0x00...0x03:  // general pen packet
            var s = PenState(x: x, y: y, distance: distance)
            let raw = (Int(d[6]) << 3) | ((Int(d[7]) & 0xC0) >> 5) | (b1 & 1)  // 11 bits
            s.pressure = raw >> 1                                             // Intuos 3 is 10-bit
            s.tiltX = (((Int(d[7]) << 1) & 0x7e) | (Int(d[8]) >> 7)) - 64
            s.tiltY = (Int(d[8]) & 0x7f) - 64
            s.buttons = (s.pressure > 10 ? 1 : 0) | (b1 & 2) | (b1 & 4)
            return .pen(s)
        case 0x08 where kind == .mouse:  // Intuos 3 2D mouse packet
            let b8 = Int(d[8])
            let buttons = (b8 & 0x04 != 0 ? 1 : 0) | (b8 & 0x10 != 0 ? 2 : 0) | (b8 & 0x08 != 0 ? 4 : 0)
                | (b8 & 0x40 != 0 ? 8 : 0) | (b8 & 0x20 != 0 ? 16 : 0)
            let wheel = (b8 & 0x01) - ((b8 & 0x02) >> 1)
            return .mouse(x: x, y: y, buttons: buttons, wheel: wheel)
        default:
            return nil  // airbrush wheel / marker rotation: not handled
        }
    }

    private func parsePad(_ d: [UInt8]) -> TabletEvent {
        // 6x8 has 8 ExpressKeys: left block in d[5] low nibble, right block in d[6] low nibble.
        let buttons = (Int(d[5]) & 0x0f) | ((Int(d[6]) & 0x0f) << 4)
        let strip1 = ((Int(d[1]) & 0x1f) << 8) | Int(d[2])
        let strip2 = ((Int(d[3]) & 0x1f) << 8) | Int(d[4])
        return .pad(buttons: buttons, leftStrip: Self.stripPosition(strip1), rightStrip: Self.stripPosition(strip2))
    }

    /// Strips report a one-hot 13-bit mask (bit n set = finger at segment n). Returns 1-based segment, 0 = none.
    static func stripPosition(_ mask: Int) -> Int {
        mask == 0 ? 0 : (Int.bitWidth - mask.leadingZeroBitCount)
    }
}
