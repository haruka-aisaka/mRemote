import Foundation

/// Converts between a Swift `String` and the `CF_UNICODETEXT` bytes CLIPRDR
/// carries: UTF-16LE, CRLF line ends, one trailing NUL.
///
/// docs/architecture.md section 9 lists the edge cases, and each is decided
/// here rather than at a call site: line ends are converted explicitly in
/// both directions, an embedded NUL is refused on the way out (Windows would
/// silently truncate there), and on the way in the text ends at the first
/// NUL, because whatever follows it is not part of the clipboard.
public enum ClipboardTextCodec {
    /// Mirrors MR_RDP_MAX_CLIPBOARD_TEXT_UTF16LE_BYTES.
    public static let maximumByteCount = 4 * 1_024 * 1_024

    public enum EncodingError: Error, Hashable, Sendable {
        case empty
        case containsNUL
        case tooLarge(byteCount: Int)
    }

    public static func encode(_ text: String) throws -> Data {
        guard !text.isEmpty else { throw EncodingError.empty }
        guard !text.unicodeScalars.contains("\0") else { throw EncodingError.containsNUL }
        // CR LF and lone CR are left as they are; only bare LF is widened.
        var windows = ""
        windows.reserveCapacity(text.utf16.count)
        var previous: Character?
        for character in text {
            if character == "\n", previous != "\r" {
                windows.append("\r\n")
            } else {
                windows.append(character)
            }
            previous = character
        }
        let units = Array(windows.utf16) + [0]
        let byteCount = units.count * 2
        guard byteCount <= maximumByteCount else {
            throw EncodingError.tooLarge(byteCount: byteCount)
        }
        var data = Data(capacity: byteCount)
        for unit in units {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }

    /// Ill-formed UTF-16 (an unpaired surrogate) decodes to U+FFFD rather
    /// than failing: it came from someone else's clipboard, and the rest of
    /// the text is still worth having.
    public static func decode(_ data: Data) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let unit = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }
}
