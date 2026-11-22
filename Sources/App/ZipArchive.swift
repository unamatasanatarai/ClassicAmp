import Foundation
import Compression

/// Minimal, memory-capped, in-process ZIP reader used for `.wsz` skin archives.
///
/// Supports STORED (0) and DEFLATE (8) entries, validates CRC-32, rejects
/// path-traversal names, and enforces per-entry and total uncompressed size caps
/// to defeat decompression bombs. Never spawns a subprocess.
public enum ZipArchive {
    public enum ZipError: Error, CustomStringConvertible {
        case notAZip
        case truncated
        case entryTooLarge(String)
        case archiveTooLarge
        case unsafePath(String)
        case unsupportedCompression(String)
        case corruptEntry(String)

        public var description: String {
            switch self {
            case .notAZip: return "Not a ZIP archive"
            case .truncated: return "Archive is truncated"
            case .entryTooLarge(let n): return "Entry exceeds 32 MB: \(n)"
            case .archiveTooLarge: return "Archive exceeds 96 MB uncompressed"
            case .unsafePath(let n): return "Unsafe path in archive: \(n)"
            case .unsupportedCompression(let n): return "Unsupported compression for \(n)"
            case .corruptEntry(let n): return "Corrupt entry (CRC/size mismatch): \(n)"
            }
        }
    }

    public static let maxEntrySize = 32 * 1024 * 1024
    public static let maxTotalSize = 96 * 1024 * 1024

    /// Extracts file entries. Keys are the entry's base filename, lowercased
    /// (skins frequently nest files in a folder; the classic player ignores that folder).
    /// `wanted` (given the lowercased base name) skips entries the caller has no use for
    /// before they are inflated, so junk in an archive costs neither CPU nor memory.
    public static func extract(data: Data, wanted: ((String) -> Bool)? = nil) throws -> [String: Data] {
        // Parse in place: no copy of the whole archive.
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String: Data] in
            try extract(raw.bindMemory(to: UInt8.self), wanted: wanted)
        }
    }

    private static func extract(_ bytes: UnsafeBufferPointer<UInt8>, wanted: ((String) -> Bool)?) throws -> [String: Data] {
        let count = bytes.count
        guard count >= 22, let basePtr = bytes.baseAddress else { throw ZipError.notAZip }

        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        // Locate End Of Central Directory record (scan back over a possible comment).
        var eocd = -1
        var i = count - 22
        let lowerBound = max(0, count - 22 - 0xFFFF)
        while i >= lowerBound {
            if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let entryCount = u16(eocd + 10)
        let cdOffset = u32(eocd + 16)
        guard cdOffset < count else { throw ZipError.truncated }

        var result: [String: Data] = [:]
        var total = 0
        var p = cdOffset

        for _ in 0..<entryCount {
            guard p + 46 <= count, u32(p) == 0x02014B50 else { throw ZipError.truncated }
            let method = u16(p + 10)
            let crc = UInt32(truncatingIfNeeded: u32(p + 16))
            let compSize = u32(p + 20)
            let uncompSize = u32(p + 24)
            let nameLen = u16(p + 28)
            let extraLen = u16(p + 30)
            let commentLen = u16(p + 32)
            let localOffset = u32(p + 42)
            guard p + 46 + nameLen <= count else { throw ZipError.truncated }
            let name = String(decoding: UnsafeBufferPointer(start: basePtr + p + 46, count: nameLen), as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            if name.hasSuffix("/") { continue } // directory entry

            let normalized = name.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/")
            if normalized.hasPrefix("/") || components.contains("..") {
                throw ZipError.unsafePath(name)
            }
            guard let base = components.last, !base.isEmpty else { continue }
            if base.hasPrefix(".") || normalized.hasPrefix("__MACOSX") { continue }
            let key = base.lowercased()
            if let wanted = wanted, !wanted(key) { continue }

            if uncompSize > maxEntrySize { throw ZipError.entryTooLarge(name) }
            total += uncompSize
            if total > maxTotalSize { throw ZipError.archiveTooLarge }

            guard localOffset + 30 <= count, u32(localOffset) == 0x04034B50 else { throw ZipError.truncated }
            let dataStart = localOffset + 30 + u16(localOffset + 26) + u16(localOffset + 28)
            guard dataStart + compSize <= count else { throw ZipError.truncated }

            let payload: Data
            switch method {
            case 0:
                guard compSize == uncompSize else { throw ZipError.corruptEntry(name) }
                payload = Data(bytes: basePtr + dataStart, count: compSize)
            case 8:
                payload = try inflate(basePtr + dataStart, length: compSize, expected: uncompSize, name: name)
            default:
                throw ZipError.unsupportedCompression(name)
            }

            guard crc32(payload) == crc else { throw ZipError.corruptEntry(name) }
            result[key] = payload
        }
        return result
    }

    private static func inflate(_ src: UnsafePointer<UInt8>, length: Int, expected: Int, name: String) throws -> Data {
        if expected == 0 { return Data() }
        // +1 so that an entry which decodes to *more* than declared is detected.
        var out = Data(count: expected + 1)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected + 1,
                                      src, length, nil, COMPRESSION_ZLIB)
        }
        guard written == expected else { throw ZipError.corruptEntry(name) }
        out.count = expected
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    public static func crc32(_ data: [UInt8]) -> UInt32 {
        data.withUnsafeBufferPointer { crc32($0) }
    }

    public static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { crc32($0.bindMemory(to: UInt8.self)) }
    }

    private static func crc32(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        crcTable.withUnsafeBufferPointer { table in
            var c: UInt32 = 0xFFFFFFFF
            for b in bytes {
                c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
            }
            return c ^ 0xFFFFFFFF
        }
    }
}
