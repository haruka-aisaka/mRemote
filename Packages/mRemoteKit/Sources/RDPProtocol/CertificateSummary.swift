import Foundation

/// The human-readable parts of a leaf certificate.
///
/// Only the fingerprint establishes identity - docs/data-and-security.md is
/// explicit that subject and issuer are for display - but the review sheet
/// still has to show the user what they are being asked about, and
/// `CertificateChallenge` has carried a validity window since Phase 1.
public struct CertificateSummary: Hashable, Sendable {
    public let subject: String
    public let issuer: String
    public let notBefore: Date
    public let notAfter: Date

    public init(subject: String, issuer: String, notBefore: Date, notAfter: Date) {
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
    }
}

/// A deliberately small DER reader for the four fields above.
///
/// Security.framework has no iOS API for a certificate's validity window -
/// `SecCertificateCopyValues` is macOS only - so the alternative to parsing
/// them is showing the user a review sheet with the dates missing. The parser
/// only walks as far as `TBSCertificate.subject` and treats every length,
/// index and tag defensively: it is reading bytes that arrived from the
/// network, so a malformed certificate has to produce nil rather than a trap.
public enum CertificateSummaryParser {
    public static func summary(fromLeafDER der: Data) -> CertificateSummary? {
        var reader = DERReader(der)
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
        guard var certificate = reader.readConstructed(tag: .sequence),
              var tbs = certificate.readConstructed(tag: .sequence) else {
            return nil
        }
        // version [0] EXPLICIT, present for v2/v3 and absent for v1.
        _ = tbs.skipIfPresent(tag: .contextConstructed0)
        guard tbs.skip(tag: .integer),          // serialNumber
              tbs.skip(tag: .sequence),         // signature AlgorithmIdentifier
              let issuer = tbs.readName(),
              var validity = tbs.readConstructed(tag: .sequence),
              let notBefore = validity.readTime(),
              let notAfter = validity.readTime(),
              let subject = tbs.readName() else {
            return nil
        }
        return CertificateSummary(
            subject: subject,
            issuer: issuer,
            notBefore: notBefore,
            notAfter: notAfter
        )
    }
}

/// A cursor over one DER region. Every read is bounds-checked and every
/// failure is a nil, so no input can push an index past the end.
private struct DERReader {
    enum Tag: UInt8 {
        case integer = 0x02
        case bitString = 0x03
        case octetString = 0x04
        case objectIdentifier = 0x06
        case utf8String = 0x0C
        case printableString = 0x13
        case teletexString = 0x14
        case ia5String = 0x16
        case utcTime = 0x17
        case generalizedTime = 0x18
        case bmpString = 0x1E
        case sequence = 0x30
        case set = 0x31
        case contextConstructed0 = 0xA0
    }

    private let bytes: [UInt8]
    private var index: Int

    init(_ data: Data) {
        bytes = [UInt8](data)
        index = 0
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
        index = 0
    }

    var isAtEnd: Bool { index >= bytes.count }

    /// Reads one tag-length-value and returns its contents, or nil when the
    /// next element is not `tag` or its length runs past the end.
    mutating func readValue(tag: Tag) -> [UInt8]? {
        let saved = index
        guard index < bytes.count, bytes[index] == tag.rawValue else { return nil }
        index += 1
        guard let length = readLength(), index + length <= bytes.count else {
            index = saved
            return nil
        }
        let value = Array(bytes[index..<(index + length)])
        index += length
        return value
    }

    /// Peeks at the next tag without consuming it.
    func peekTag() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func readConstructed(tag: Tag) -> DERReader? {
        guard let value = readValue(tag: tag) else { return nil }
        return DERReader(bytes: value)
    }

    @discardableResult
    mutating func skip(tag: Tag) -> Bool {
        readValue(tag: tag) != nil
    }

    @discardableResult
    mutating func skipIfPresent(tag: Tag) -> Bool {
        guard peekTag() == tag.rawValue else { return false }
        return skip(tag: tag)
    }

    private mutating func readLength() -> Int? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        index += 1
        if first < 0x80 { return Int(first) }
        let byteCount = Int(first & 0x7F)
        // 0x80 is the indefinite form, which DER forbids, and more than eight
        // length bytes cannot describe anything this parser will ever hold.
        guard byteCount > 0, byteCount <= 8, index + byteCount <= bytes.count else { return nil }
        var length = 0
        for offset in 0..<byteCount {
            let (shifted, overflow) = length.multipliedReportingOverflow(by: 256)
            guard !overflow else { return nil }
            length = shifted + Int(bytes[index + offset])
        }
        index += byteCount
        guard length >= 0 else { return nil }
        return length
    }

    /// Name ::= RDNSequence ::= SEQUENCE OF SET OF AttributeTypeAndValue,
    /// rendered the way a certificate viewer shows it.
    mutating func readName() -> String? {
        guard var sequence = readConstructed(tag: .sequence) else { return nil }
        var components: [String] = []
        while !sequence.isAtEnd {
            guard var set = sequence.readConstructed(tag: .set) else { return nil }
            while !set.isAtEnd {
                guard var pair = set.readConstructed(tag: .sequence),
                      let oid = pair.readValue(tag: .objectIdentifier),
                      let value = pair.readDirectoryString() else {
                    return nil
                }
                components.append("\(Self.attributeName(for: oid))=\(value)")
            }
        }
        // An empty Name is legal DER and means the certificate asserts no
        // name at all, which the review sheet should say rather than leave
        // blank.
        return components.isEmpty ? "(no name)" : components.joined(separator: ", ")
    }

    /// DirectoryString and the string types certificates actually use for it.
    private mutating func readDirectoryString() -> String? {
        for tag in [Tag.utf8String, .printableString, .ia5String, .teletexString] {
            if let value = readValue(tag: tag) {
                return String(decoding: value, as: UTF8.self)
            }
        }
        if let value = readValue(tag: .bmpString) {
            // BMPString is UTF-16BE.
            guard value.count.isMultiple(of: 2) else { return nil }
            var scalars = ""
            for offset in stride(from: 0, to: value.count, by: 2) {
                let code = UInt16(value[offset]) << 8 | UInt16(value[offset + 1])
                guard let scalar = Unicode.Scalar(code) else { return nil }
                scalars.unicodeScalars.append(scalar)
            }
            return scalars
        }
        return nil
    }

    /// Time ::= UTCTime | GeneralizedTime.
    mutating func readTime() -> Date? {
        if let value = readValue(tag: .utcTime) {
            return Self.date(from: value, formats: ["yyMMddHHmmss'Z'", "yyMMddHHmm'Z'"])
        }
        if let value = readValue(tag: .generalizedTime) {
            return Self.date(from: value, formats: ["yyyyMMddHHmmss'Z'", "yyyyMMddHHmm'Z'"])
        }
        return nil
    }

    private static func date(from bytes: [UInt8], formats: [String]) -> Date? {
        let text = String(decoding: bytes, as: UTF8.self)
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// The attribute types a server certificate actually carries. Anything
    /// else is shown in dotted form rather than dropped, so an unusual name
    /// is still legible.
    private static func attributeName(for oid: [UInt8]) -> String {
        switch oid {
        case [0x55, 0x04, 0x03]: return "CN"
        case [0x55, 0x04, 0x06]: return "C"
        case [0x55, 0x04, 0x07]: return "L"
        case [0x55, 0x04, 0x08]: return "ST"
        case [0x55, 0x04, 0x0A]: return "O"
        case [0x55, 0x04, 0x0B]: return "OU"
        case [0x55, 0x04, 0x05]: return "serialNumber"
        case [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x01]: return "emailAddress"
        case [0x09, 0x92, 0x26, 0x89, 0x93, 0xF2, 0x2C, 0x64, 0x01, 0x19]: return "DC"
        default: return dottedOID(oid)
        }
    }

    private static func dottedOID(_ oid: [UInt8]) -> String {
        guard let first = oid.first else { return "?" }
        var components = [String(first / 40), String(first % 40)]
        var value = 0
        var overflowed = false
        for byte in oid.dropFirst() {
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 128)
            if overflow { overflowed = true; break }
            value = shifted + Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                components.append(String(value))
                value = 0
            }
        }
        return overflowed ? "?" : components.joined(separator: ".")
    }
}
