import Carbon
import Foundation

/// The character the current keyboard layout types for a key pressed with ⌥ alone.
public enum KeyboardGlyph {
    /// nil when the letter stays the same or cannot be read. Warnings ("⌥F types ƒ") appear only when the character changes.
    public static func optionOnlyCharacter(keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { pointer -> String? in
            guard let base = pointer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0
            let status = UCKeyTranslate(
                base, UInt16(keyCode), UInt16(kUCKeyActionDisplay), UInt32(optionKey >> 8),
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: Int(length)).trimmingCharacters(in: .controlCharacters)
            return text.isEmpty ? nil : text
        }
    }
}
