import Foundation

/// A stored (uncompressed) zip written as it is read, so "Download all" never holds a file in memory
/// or on disk. Sizes are known up front, which makes the Content-Length exact; the CRC is not, so
/// every entry trails a data descriptor. ZIP64 records appear only where a size or offset needs them.
public struct RemoteZipStream {

    public struct Entry: Sendable, Equatable {
        /// The path inside the archive: relative, `/`-separated, never `..`.
        public var name: String
        public var path: String
        public var size: Int64
        public var modified: Date
        /// The folder the opened file's real path must stay inside.
        public var root: String

        public init(name: String, path: String, size: Int64, modified: Date, root: String? = nil) {
            self.name = name
            self.path = path
            self.size = size
            self.modified = modified
            self.root = root ?? (path as NSString).deletingLastPathComponent
        }
    }

    static let u32max: Int64 = 0xFFFF_FFFF
    static let u16max = 0xFFFF
    static let chunkSize = 512 * 1024

    let entries: [Entry]
    private let names: [Data]
    private let offsets: [Int64]
    private let centralStart: Int64
    private let centralSize: Int64
    /// Every byte `next()` will produce, when every file reads back at its planned size.
    public let contentLength: Int64

    private enum Phase {
        case local(Int)
        case body(Int, FileHandle, remaining: Int64)
        case descriptor(Int)
        case central
        case done
    }
    private var phase: Phase
    private var crcs: [UInt32]
    private var crc: UInt32 = 0

    public init(entries: [Entry]) {
        self.entries = entries
        names = entries.map { Data($0.name.utf8) }
        var offset: Int64 = 0
        var offsets: [Int64] = []
        for (i, entry) in entries.enumerated() {
            offsets.append(offset)
            offset += Self.localHeaderLength(entry, name: names[i]) + entry.size
                + (Self.isZip64(entry) ? 24 : 16)
        }
        self.offsets = offsets
        centralStart = offset
        var central: Int64 = 0
        for (i, entry) in entries.enumerated() {
            let extra = Self.isZip64(entry) || offsets[i] >= Self.u32max ? 28 : 0
            central += 46 + Int64(names[i].count) + Int64(extra)
        }
        centralSize = central
        let needs64 = entries.count >= Self.u16max || centralStart >= Self.u32max
            || centralSize >= Self.u32max
        contentLength = centralStart + centralSize + (needs64 ? 56 + 20 : 0) + 22
        crcs = Array(repeating: 0, count: entries.count)
        phase = entries.isEmpty ? .central : .local(0)
    }

    static func isZip64(_ entry: Entry) -> Bool { entry.size >= u32max }

    /// A ZIP64 entry carries the extra in its local header too: some readers decide there.
    static func localHeaderLength(_ entry: Entry, name: Data) -> Int64 {
        30 + Int64(name.count) + (isZip64(entry) ? 20 : 0)
    }

    /// The next piece of the archive, or nil when it is complete — or cut short: a file that vanished
    /// or shrank since planning ends the body early, and the client sees a length mismatch.
    public mutating func next() -> Data? {
        switch phase {
        case .local(let i):
            let entry = entries[i]
            guard let handle = RemoteServedFile.open(entry.path, within: entry.root,
                                                     minimumSize: entry.size) else {
                GoelLog.remote.notice("Zip entry missing or changed on disk; ending the archive early",
                                      .path(entry.path))
                phase = .done
                return nil
            }
            crc = 0
            phase = entry.size > 0 ? .body(i, handle, remaining: entry.size) : .descriptor(i)
            if entry.size == 0 { try? handle.close() }
            return localHeader(i)
        case .body(let i, let handle, let remaining):
            let want = Int(min(Int64(Self.chunkSize), remaining))
            guard let chunk = RemoteStreamService.readChunk(handle, upTo: want, path: entries[i].path,
                                                            offset: entries[i].size - remaining) else {
                try? handle.close()
                phase = .done
                return nil
            }
            crc = Self.crc32(chunk, seed: crc)
            let left = remaining - Int64(chunk.count)
            if left <= 0 {
                try? handle.close()
                phase = .descriptor(i)
            } else {
                phase = .body(i, handle, remaining: left)
            }
            return chunk
        case .descriptor(let i):
            crcs[i] = crc
            phase = i + 1 < entries.count ? .local(i + 1) : .central
            return descriptor(i)
        case .central:
            phase = .done
            return centralDirectory()
        case .done:
            return nil
        }
    }

    private func localHeader(_ i: Int) -> Data {
        let entry = entries[i]
        var b = ZipBytes()
        b.u32(0x0403_4b50)
        b.u16(Self.isZip64(entry) ? 45 : 20)
        b.u16(0x0808)  // data descriptor follows; name is UTF-8
        b.u16(0)       // stored
        let (time, date) = Self.dosDateTime(entry.modified)
        b.u16(time)
        b.u16(date)
        b.u32(0)       // CRC and sizes are in the descriptor
        let zip64 = Self.isZip64(entry)
        b.u32(zip64 ? UInt32(Self.u32max) : 0)
        b.u32(zip64 ? UInt32(Self.u32max) : 0)
        b.u16(names[i].count)
        b.u16(zip64 ? 20 : 0)
        b.data.append(names[i])
        if zip64 {
            // Zero, like the 32-bit fields would be: bit 3 puts the real sizes in the descriptor.
            b.u16(0x0001)
            b.u16(16)
            b.u64(0)
            b.u64(0)
        }
        return b.data
    }

    private func descriptor(_ i: Int) -> Data {
        let entry = entries[i]
        var b = ZipBytes()
        b.u32(0x0807_4b50)
        b.u32(crcs[i])
        if Self.isZip64(entry) {
            b.u64(entry.size)
            b.u64(entry.size)
        } else {
            b.u32(UInt32(entry.size))
            b.u32(UInt32(entry.size))
        }
        return b.data
    }

    private func centralDirectory() -> Data {
        var b = ZipBytes()
        for (i, entry) in entries.enumerated() {
            let offset = offsets[i]
            let extra = Self.isZip64(entry) || offset >= Self.u32max
            b.u32(0x0201_4b50)
            b.u16(3 << 8 | 45)  // made by: Unix, so the mode below is honoured
            b.u16(Self.isZip64(entry) ? 45 : 20)
            b.u16(0x0808)
            b.u16(0)
            let (time, date) = Self.dosDateTime(entry.modified)
            b.u16(time)
            b.u16(date)
            b.u32(crcs[i])
            if extra {
                b.u32(UInt32(Self.u32max))
                b.u32(UInt32(Self.u32max))
            } else {
                b.u32(UInt32(entry.size))
                b.u32(UInt32(entry.size))
            }
            b.u16(names[i].count)
            b.u16(extra ? 28 : 0)
            b.u16(0)                    // comment
            b.u16(0)                    // disk
            b.u16(0)                    // internal attributes
            b.u32(0o100644 << 16)       // -rw-r--r--
            b.u32(extra ? UInt32(Self.u32max) : UInt32(offset))
            b.data.append(names[i])
            if extra {
                b.u16(0x0001)
                b.u16(24)
                b.u64(entry.size)
                b.u64(entry.size)
                b.u64(offset)
            }
        }
        let needs64 = entries.count >= Self.u16max || centralStart >= Self.u32max
            || centralSize >= Self.u32max
        if needs64 {
            let end64 = centralStart + centralSize
            b.u32(0x0606_4b50)
            b.u64(44)
            b.u16(3 << 8 | 45)
            b.u16(45)
            b.u32(0)
            b.u32(0)
            b.u64(Int64(entries.count))
            b.u64(Int64(entries.count))
            b.u64(centralSize)
            b.u64(centralStart)
            b.u32(0x0706_4b50)
            b.u32(0)
            b.u64(end64)
            b.u32(1)
        }
        b.u32(0x0605_4b50)
        b.u16(0)
        b.u16(0)
        b.u16(needs64 ? Self.u16max : entries.count)
        b.u16(needs64 ? Self.u16max : entries.count)
        b.u32(needs64 ? UInt32(Self.u32max) : UInt32(centralSize))
        b.u32(needs64 ? UInt32(Self.u32max) : UInt32(centralStart))
        b.u16(0)
        return b.data
    }

    /// MS-DOS time and date in local time; the format cannot say anything before 1980.
    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let time = (c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2
        let day = (year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: day))
    }

    /// Slicing-by-8: eight tables, eight bytes a step. Byte-at-a-time CRC was the zip path's hot spot.
    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 8 * 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[n] = c
        }
        for n in 0..<256 {
            for k in 1..<8 {
                let prior = table[(k - 1) * 256 + n]
                table[k * 256 + n] = (prior >> 8) ^ table[Int(prior & 0xFF)]
            }
        }
        return table
    }()

    /// Little-endian 32-bit word at `i`.
    private static func word(_ p: UnsafeBufferPointer<UInt8>, at i: Int) -> UInt32 {
        let b0: UInt32 = UInt32(p[i])
        let b1: UInt32 = UInt32(p[i + 1]) << 8
        let b2: UInt32 = UInt32(p[i + 2]) << 16
        let b3: UInt32 = UInt32(p[i + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    static func crc32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            Self.crcTable.withUnsafeBufferPointer { t in
                var i = 0
                while p.count - i >= 8 {
                    // Split into typed steps: the one-expression form times out the
                    // type checker on older toolchains (Linux CI, Xcode 16).
                    let one: UInt32 = c ^ Self.word(p, at: i)
                    let two: UInt32 = Self.word(p, at: i + 4)
                    var x: UInt32 = t[7 * 256 + Int(one & 0xFF)]
                    x ^= t[6 * 256 + Int((one >> 8) & 0xFF)]
                    x ^= t[5 * 256 + Int((one >> 16) & 0xFF)]
                    x ^= t[4 * 256 + Int(one >> 24)]
                    x ^= t[3 * 256 + Int(two & 0xFF)]
                    x ^= t[2 * 256 + Int((two >> 8) & 0xFF)]
                    x ^= t[256 + Int((two >> 16) & 0xFF)]
                    x ^= t[Int(two >> 24)]
                    c = x
                    i += 8
                }
                while i < p.count {
                    c = t[Int((c ^ UInt32(p[i])) & 0xFF)] ^ (c >> 8)
                    i += 1
                }
            }
        }
        return ~c
    }
}

/// Little-endian field writer for the zip records.
private struct ZipBytes {
    var data = Data()
    mutating func u16(_ v: Int) { u16(UInt16(truncatingIfNeeded: v)) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: Int64) { withUnsafeBytes(of: UInt64(v).littleEndian) { data.append(contentsOf: $0) } }
}

/// Drives a ``RemoteZipStream`` off the server actor: each read and CRC runs on a detached task, so
/// a multi-gigabyte archive never holds up other requests. Used by one connection, one call at a time.
final class RemoteZipPump: @unchecked Sendable {
    private var zip: RemoteZipStream
    let contentLength: Int64

    init(entries: [RemoteZipStream.Entry]) {
        zip = RemoteZipStream(entries: entries)
        contentLength = zip.contentLength
    }

    func next() async -> Data? {
        await Task.detached(priority: .utility) { self.zip.next() }.value
    }
}
