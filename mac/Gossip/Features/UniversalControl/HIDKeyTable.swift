import Foundation

/// macOS virtual key codes (`kVK_*`, physical keys) to USB HID keyboard-page (0x07) usages, plus the
/// HID modifier bitmask. Pure data so a non-macOS source can reuse the usages.
enum HIDKeyTable {
    // HID modifier bits (the keyboard report's first byte).
    static let leftControl: UInt8 = 0x01, leftShift: UInt8 = 0x02, leftAlt: UInt8 = 0x04, leftMeta: UInt8 = 0x08
    static let rightControl: UInt8 = 0x10, rightShift: UInt8 = 0x20, rightAlt: UInt8 = 0x40, rightMeta: UInt8 = 0x80

    /// What the Mac Command key becomes on the device.
    enum CommandMapping: String, CaseIterable {
        /// Command acts as Control, so Cmd+C copies on Android (default).
        case control
        /// Command stays Meta (the Android/Windows key).
        case meta
    }

    /// macOS key code -> HID usage. Keys with no sensible HID equivalent are absent.
    static let usageForMacKeyCode: [UInt16: UInt16] = {
        var t: [UInt16: UInt16] = [:]
        // Letters (ANSI positions).
        let letters: [(UInt16, UInt16)] = [
            (0, 0x04), (11, 0x05), (8, 0x06), (2, 0x07), (14, 0x08), (3, 0x09), (5, 0x0A), (4, 0x0B), (34, 0x0C),
            (38, 0x0D), (40, 0x0E), (37, 0x0F), (46, 0x10), (45, 0x11), (31, 0x12), (35, 0x13), (12, 0x14),
            (15, 0x15), (1, 0x16), (17, 0x17), (32, 0x18), (9, 0x19), (13, 0x1A), (7, 0x1B), (16, 0x1C), (6, 0x1D),
        ]
        for (k, u) in letters { t[k] = u }
        // Digits row.
        let digits: [(UInt16, UInt16)] = [(18, 0x1E), (19, 0x1F), (20, 0x20), (21, 0x21), (23, 0x22), (22, 0x23), (26, 0x24), (28, 0x25), (25, 0x26), (29, 0x27)]
        for (k, u) in digits { t[k] = u }
        let punctuation: [(UInt16, UInt16)] = [
            (36, 0x28),  // Return
            (53, 0x29),  // Escape
            (51, 0x2A),  // Delete (backspace)
            (48, 0x2B),  // Tab
            (49, 0x2C),  // Space
            (27, 0x2D),  // Minus
            (24, 0x2E),  // Equal
            (33, 0x2F),  // [
            (30, 0x30),  // ]
            (42, 0x31),  // Backslash
            (41, 0x33),  // Semicolon
            (39, 0x34),  // Quote
            (50, 0x35),  // Grave
            (43, 0x36),  // Comma
            (47, 0x37),  // Period
            (44, 0x38),  // Slash
            (57, 0x39),  // Caps Lock
            (10, 0x64),  // ISO section key (non-US backslash)
        ]
        for (k, u) in punctuation { t[k] = u }
        // F1-F12.
        let f: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, k) in f.enumerated() { t[k] = UInt16(0x3A + i) }
        // F13-F20.
        let fHigh: [UInt16] = [105, 107, 113, 106, 64, 79, 80, 90]
        for (i, k) in fHigh.enumerated() { t[k] = UInt16(0x68 + i) }
        let nav: [(UInt16, UInt16)] = [
            (114, 0x49),  // Help -> Insert
            (115, 0x4A), (116, 0x4B), (117, 0x4C), (119, 0x4D), (121, 0x4E),
            (124, 0x4F), (123, 0x50), (125, 0x51), (126, 0x52),
        ]
        for (k, u) in nav { t[k] = u }
        // Keypad.
        let keypad: [(UInt16, UInt16)] = [
            (71, 0x53), (75, 0x54), (67, 0x55), (78, 0x56), (69, 0x57), (76, 0x58),
            (83, 0x59), (84, 0x5A), (85, 0x5B), (86, 0x5C), (87, 0x5D), (88, 0x5E), (89, 0x5F), (91, 0x60), (92, 0x61),
            (82, 0x62), (65, 0x63), (81, 0x67), (95, 0x85),
        ]
        for (k, u) in keypad { t[k] = u }
        // JIS extras.
        t[93] = 0x89   // Yen
        t[94] = 0x87   // Underscore / Ro
        t[102] = 0x91  // Eisu -> Lang2
        t[104] = 0x90  // Kana -> Lang1
        // Media keys that arrive as regular key codes.
        t[74] = 0x7F; t[72] = 0x80; t[73] = 0x81
        // Modifiers as usages (the device also gets them in the modifier byte).
        t[59] = 0xE0; t[56] = 0xE1; t[58] = 0xE2; t[55] = 0xE3
        t[62] = 0xE4; t[60] = 0xE5; t[61] = 0xE6; t[54] = 0xE7
        return t
    }()

    /// The modifier bit a macOS modifier key code contributes, before Command remapping.
    static func modifierBit(forMacKeyCode code: UInt16, command: CommandMapping) -> UInt8? {
        switch code {
        case 59: return leftControl
        case 62: return rightControl
        case 56: return leftShift
        case 60: return rightShift
        case 58: return leftAlt
        case 61: return rightAlt
        case 55: return command == .control ? leftControl : leftMeta
        case 54: return command == .control ? rightControl : rightMeta
        default: return nil
        }
    }

    /// The HID usage to send for a macOS key code, applying the Command remapping to the Command keys.
    static func usage(forMacKeyCode code: UInt16, command: CommandMapping) -> UInt16? {
        switch code {
        case 55: return command == .control ? 0xE0 : 0xE3
        case 54: return command == .control ? 0xE4 : 0xE7
        default: return usageForMacKeyCode[code]
        }
    }

    /// Modifier byte from macOS `CGEventFlags`-style booleans.
    static func modifierByte(shift: Bool, control: Bool, option: Bool, command: Bool, mapping: CommandMapping) -> UInt8 {
        var m: UInt8 = 0
        if shift { m |= leftShift }
        if control { m |= leftControl }
        if option { m |= leftAlt }
        if command { m |= mapping == .control ? leftControl : leftMeta }
        return m
    }
}
