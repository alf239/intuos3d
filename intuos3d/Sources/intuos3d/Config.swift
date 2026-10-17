import CoreGraphics
import Foundation

struct Config: Codable {
    enum PenButton: String, Codable {
        case none, left, right, middle
        var cgButton: CGMouseButton? {
            switch self {
            case .none: return nil
            case .left: return .left
            case .right: return .right
            case .middle: return .center
            }
        }
    }

    /// "fit" keeps the screen's aspect ratio (uses a centred sub-area of the tablet); "stretch" uses the whole tablet.
    var mapping = "fit"
    /// Pressure curve exponent; 1.0 = linear, <1 softer, >1 firmer.
    var pressureGamma = 1.0
    var penButton1 = PenButton.right
    var penButton2 = PenButton.middle
    /// Actions for ExpressKeys 1-4 (left block, top to bottom) and 5-8 (right block). Held while pressed.
    var expressKeys = ["shift", "option", "cmd", "space", "cmd+z", "cmd+shift+z", "[", "]"]
    /// Touch strips: [action per segment when the finger slides down, action when it slides up].
    /// Segment 1 is the top of the strip, 13 the bottom. "scroll:N" or a key chord.
    var leftStrip = ["scroll:-1", "scroll:1"]
    var rightStrip = ["cmd+-", "cmd+="]
    /// Print every HID report and parsed event to the log (same as the --log flag).
    var logReports = false

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/intuos3d/config.json")

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mapping = try c.decodeIfPresent(String.self, forKey: .mapping) ?? mapping
        pressureGamma = try c.decodeIfPresent(Double.self, forKey: .pressureGamma) ?? pressureGamma
        penButton1 = try c.decodeIfPresent(PenButton.self, forKey: .penButton1) ?? penButton1
        penButton2 = try c.decodeIfPresent(PenButton.self, forKey: .penButton2) ?? penButton2
        expressKeys = try c.decodeIfPresent([String].self, forKey: .expressKeys) ?? expressKeys
        leftStrip = try c.decodeIfPresent([String].self, forKey: .leftStrip) ?? leftStrip
        rightStrip = try c.decodeIfPresent([String].self, forKey: .rightStrip) ?? rightStrip
        logReports = try c.decodeIfPresent(Bool.self, forKey: .logReports) ?? logReports
    }

    /// Loads the config, writing the defaults to disk the first time so the user has something to edit.
    static func load() -> Config {
        if let data = try? Data(contentsOf: path) {
            do { return try JSONDecoder().decode(Config.self, from: data) }
            catch { log("config.json is invalid (\(error)); using defaults") }
            return Config()
        }
        let c = Config()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(c).write(to: path)
        return c
    }
}

/// A key chord ("cmd+shift+z", "space", "f5"), a modifier held on its own ("shift"), a scroll ("scroll:3") or "none".
struct KeyAction {
    enum Kind { case none, key(CGKeyCode, CGEventFlags, modifierOnly: Bool), scroll(Int32) }
    let kind: Kind

    init(_ spec: String) {
        let s = spec.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s == "none" { kind = .none; return }
        if s.hasPrefix("scroll:") { kind = .scroll(Int32(s.dropFirst(7)) ?? 0); return }
        var flags = CGEventFlags()
        var code: CGKeyCode?
        for part in s.split(separator: "+").map(String.init) {
            if let m = KeyAction.modifiers[part] { flags.insert(m.flag); code = code ?? m.code }
            else if let k = KeyAction.keyCodes[part] { code = k }
            else { log("unknown key '\(part)' in action '\(spec)'") }
        }
        guard let c = code else { kind = .none; return }
        let modifierOnly = KeyAction.modifiers.values.contains { $0.code == c } && !KeyAction.keyCodes.values.contains(c)
        kind = .key(c, flags, modifierOnly: modifierOnly)
    }

    func post(down: Bool) {
        switch kind {
        case .none: break
        case .key(let code, let flags, let modifierOnly):
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
            e.flags = (modifierOnly && !down) ? [] : flags
            e.post(tap: .cghidEventTap)
        case .scroll(let lines):
            guard down, let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                        wheel1: lines, wheel2: 0, wheel3: 0) else { return }
            e.post(tap: .cghidEventTap)
        }
    }

    func tap(times: Int = 1) { for _ in 0..<max(times, 1) { post(down: true); post(down: false) } }

    static let modifiers: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
        "cmd": (55, .maskCommand), "command": (55, .maskCommand),
        "shift": (56, .maskShift),
        "option": (58, .maskAlternate), "alt": (58, .maskAlternate),
        "ctrl": (59, .maskControl), "control": (59, .maskControl),
    ]

    // ANSI US layout virtual key codes (Carbon kVK_*).
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "f17": 64, "f18": 79, "f19": 80, "f20": 90, "f5": 96, "f6": 97, "f7": 98,
        "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109,
        "f12": 111, "f15": 113, "home": 115, "pageup": 116, "forwarddelete": 117, "f4": 118, "end": 119,
        "f2": 120, "pagedown": 121, "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
