import Foundation
import CoreGraphics

// MARK: - Public API

enum ScrubError: LocalizedError {
    case notPDF
    case encrypted
    case malformed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .notPDF: return "Not a PDF file."
        case .encrypted: return "Password-protected PDFs aren't supported."
        case .malformed(let why): return "Couldn't read this PDF (\(why))."
        case .verificationFailed: return "The updated PDF didn't pass a safety check, so the file was left unchanged."
        }
    }
}

/// Rewrites a PDF's metadata in place:
/// - Author / Creator / Producer → company name
/// - Keywords removed
/// - Any other "Canva" in the metadata → company name
/// - ModDate → now
/// - Strips macOS "Where from" + quarantine extended attributes
///
/// Page content is never touched. When the new metadata fits in the space the old
/// metadata occupied it is overwritten in place; otherwise the new metadata is appended
/// as a standard PDF incremental update and the old copy is blanked out.
struct PDFScrubber {
    var company: String
    var now = Date()

    func scrub(url: URL) throws {
        let original = try Data(contentsOf: url)
        var doc = try PDFFile(bytes: [UInt8](original))
        let edit = try doc.makeEdit(company: company, now: now)

        // Build the full result in memory and verify it before touching the real file.
        var result = doc.bytes
        for patch in edit.patches { result.replaceSubrange(patch.offset..<(patch.offset + patch.bytes.count), with: patch.bytes) }
        result.append(contentsOf: edit.appended)
        try verify(original: original, updated: Data(result), expectedProducer: edit.producer)

        // Apply to the original file in place (keeps the file's identity, creation date, Finder tags…).
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        for patch in edit.patches {
            try handle.seek(toOffset: UInt64(patch.offset))
            try handle.write(contentsOf: patch.bytes)
        }
        if !edit.appended.isEmpty {
            try handle.seekToEnd()
            try handle.write(contentsOf: edit.appended)
        }
        try handle.synchronize()
        try handle.close()

        for name in ["com.apple.metadata:kMDItemWhereFroms",
                     "com.apple.metadata:kMDItemDownloadedDate",
                     "com.apple.quarantine"] {
            removexattr(url.path, name, 0)
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    private func verify(original: Data, updated: Data, expectedProducer: String) throws {
        func open(_ d: Data) -> CGPDFDocument? {
            guard let provider = CGDataProvider(data: d as CFData) else { return nil }
            return CGPDFDocument(provider)
        }
        guard let before = open(original) else { throw ScrubError.malformed("unreadable") }
        guard let after = open(updated), after.numberOfPages == before.numberOfPages,
              let info = after.info else { throw ScrubError.verificationFailed }
        var producer: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "Producer", &producer), let p = producer,
              let s = CGPDFStringCopyTextString(p) as String?, s == expectedProducer
        else { throw ScrubError.verificationFailed }
    }
}

// MARK: - PDF object model

indirect enum PDFObject {
    case null
    case bool(Bool)
    case int(Int)
    case real(String)
    case name(String)          // raw, without the leading slash
    case string([UInt8])
    case array([PDFObject])
    case dict([(String, PDFObject)])
    case ref(Int, Int)

    subscript(key: String) -> PDFObject? {
        if case .dict(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }
    var intValue: Int? { if case .int(let i) = self { return i }; return nil }

    func serialized() -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .real(let r): return r
        case .name(let n): return "/" + n
        case .ref(let n, let g): return "\(n) \(g) R"
        case .array(let items): return "[" + items.map { $0.serialized() }.joined(separator: " ") + "]"
        case .dict(let pairs): return "<<\n" + pairs.map { "/\($0.0) \($0.1.serialized())" }.joined(separator: "\n") + "\n>>"
        case .string(let bytes):
            if bytes.contains(where: { $0 < 0x20 || $0 > 0x7E }) {
                return "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
            }
            var s = "("
            for b in bytes {
                switch b {
                case 0x28: s += "\\("
                case 0x29: s += "\\)"
                case 0x5C: s += "\\\\"
                case 0x20...0x7E: s.unicodeScalars.append(UnicodeScalar(b))
                default: s += String(format: "\\%03o", b)
                }
            }
            return s + ")"
        }
    }
}

// MARK: - Text encoding (PDFDocEncoding / UTF-16BE)

enum PDFText {
    private static let high: [UInt8: UInt16] = [
        0x80: 0x2022, 0x81: 0x2020, 0x82: 0x2021, 0x83: 0x2026, 0x84: 0x2014, 0x85: 0x2013,
        0x86: 0x0192, 0x87: 0x2044, 0x88: 0x2039, 0x89: 0x203A, 0x8A: 0x2212, 0x8B: 0x2030,
        0x8C: 0x201E, 0x8D: 0x201C, 0x8E: 0x201D, 0x8F: 0x2018, 0x90: 0x2019, 0x91: 0x201A,
        0x92: 0x2122, 0x93: 0xFB01, 0x94: 0xFB02, 0x95: 0x0141, 0x96: 0x0152, 0x97: 0x0160,
        0x98: 0x0178, 0x99: 0x017D, 0x9A: 0x0131, 0x9B: 0x0142, 0x9C: 0x0153, 0x9D: 0x0161,
        0x9E: 0x017E, 0xA0: 0x20AC,
    ]
    private static let reverse: [UInt16: UInt8] = Dictionary(uniqueKeysWithValues: high.map { ($1, $0) })

    static func decode(_ bytes: [UInt8]) -> String {
        if bytes.starts(with: [0xFE, 0xFF]) {
            var units: [UInt16] = []
            var i = 2
            while i + 1 < bytes.count { units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        var s = ""
        for b in bytes {
            if let u = high[b], let scalar = UnicodeScalar(u) { s.unicodeScalars.append(scalar) }
            else { s.unicodeScalars.append(UnicodeScalar(b)) }
        }
        return s
    }

    static func encode(_ string: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in string.unicodeScalars {
            let v = scalar.value
            if (0x20...0x7E).contains(v) || (0xA1...0xFF).contains(v) && v != 0xAD || v == 0x0A || v == 0x09 {
                out.append(UInt8(v))
            } else if v <= 0xFFFF, let b = reverse[UInt16(v)] {
                out.append(b)
            } else {
                var utf16: [UInt8] = [0xFE, 0xFF]
                for u in string.utf16 { utf16.append(UInt8(u >> 8)); utf16.append(UInt8(u & 0xFF)) }
                return utf16
            }
        }
        return out
    }
}

// MARK: - Parser

struct PDFParser {
    let b: [UInt8]
    var p: Int

    init(_ bytes: [UInt8], at position: Int) { b = bytes; p = position }

    static func isWhite(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
    static func isDelim(_ c: UInt8) -> Bool {
        c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25
    }
    static func isRegular(_ c: UInt8) -> Bool { !isWhite(c) && !isDelim(c) }

    mutating func skipWhitespace() {
        while p < b.count {
            let c = b[p]
            if PDFParser.isWhite(c) { p += 1 }
            else if c == 0x25 { while p < b.count && b[p] != 10 && b[p] != 13 { p += 1 } }
            else { break }
        }
    }

    mutating func readToken() -> String {
        let start = p
        while p < b.count && PDFParser.isRegular(b[p]) { p += 1 }
        return String(decoding: b[start..<p], as: UTF8.self)
    }

    func matches(_ keyword: String, at pos: Int) -> Bool {
        let k = Array(keyword.utf8)
        guard pos + k.count <= b.count else { return false }
        return Array(b[pos..<(pos + k.count)]) == k
    }

    mutating func parse() throws -> PDFObject {
        skipWhitespace()
        guard p < b.count else { throw ScrubError.malformed("unexpected end of file") }
        switch b[p] {
        case 0x2F: // /
            p += 1
            return .name(readToken())
        case 0x28: // (
            return .string(try readLiteralString())
        case 0x3C: // <
            if p + 1 < b.count && b[p + 1] == 0x3C {
                p += 2
                var pairs: [(String, PDFObject)] = []
                while true {
                    skipWhitespace()
                    guard p + 1 < b.count else { throw ScrubError.malformed("unterminated dictionary") }
                    if b[p] == 0x3E && b[p + 1] == 0x3E { p += 2; break }
                    guard b[p] == 0x2F else { throw ScrubError.malformed("bad dictionary key") }
                    p += 1
                    let key = readToken()
                    pairs.append((key, try parse()))
                }
                return .dict(pairs)
            }
            return .string(try readHexString())
        case 0x5B: // [
            p += 1
            var items: [PDFObject] = []
            while true {
                skipWhitespace()
                guard p < b.count else { throw ScrubError.malformed("unterminated array") }
                if b[p] == 0x5D { p += 1; break }
                items.append(try parse())
            }
            return .array(items)
        default:
            let token = readToken()
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "": throw ScrubError.malformed("unexpected character")
            default:
                if let n = Int(token) {
                    let save = p
                    skipWhitespace()
                    if let g = Int(readToken()) {
                        skipWhitespace()
                        if p < b.count && b[p] == 0x52 && (p + 1 >= b.count || !PDFParser.isRegular(b[p + 1])) {
                            p += 1
                            return .ref(n, g)
                        }
                    }
                    p = save
                    return .int(n)
                }
                if Double(token) != nil { return .real(token) }
                throw ScrubError.malformed("unexpected keyword \(token)")
            }
        }
    }

    private mutating func readLiteralString() throws -> [UInt8] {
        p += 1
        var out: [UInt8] = []
        var depth = 1
        while p < b.count {
            let c = b[p]; p += 1
            switch c {
            case 0x5C:
                guard p < b.count else { break }
                let e = b[p]; p += 1
                switch e {
                case 0x6E: out.append(10)
                case 0x72: out.append(13)
                case 0x74: out.append(9)
                case 0x62: out.append(8)
                case 0x66: out.append(12)
                case 0x0D: if p < b.count && b[p] == 0x0A { p += 1 }
                case 0x0A: break
                case 0x30...0x37:
                    var v = Int(e - 0x30)
                    var n = 1
                    while n < 3 && p < b.count && (0x30...0x37).contains(b[p]) { v = v * 8 + Int(b[p] - 0x30); p += 1; n += 1 }
                    out.append(UInt8(v & 0xFF))
                default: out.append(e)
                }
            case 0x28: depth += 1; out.append(c)
            case 0x29:
                depth -= 1
                if depth == 0 { return out }
                out.append(c)
            case 0x0D:
                if p < b.count && b[p] == 0x0A { p += 1 }
                out.append(10)
            default: out.append(c)
            }
        }
        throw ScrubError.malformed("unterminated string")
    }

    private mutating func readHexString() throws -> [UInt8] {
        p += 1
        var digits: [UInt8] = []
        while p < b.count && b[p] != 0x3E {
            let c = b[p]; p += 1
            switch c {
            case 0x30...0x39: digits.append(c - 0x30)
            case 0x41...0x46: digits.append(c - 0x41 + 10)
            case 0x61...0x66: digits.append(c - 0x61 + 10)
            default: continue
            }
        }
        guard p < b.count else { throw ScrubError.malformed("unterminated hex string") }
        p += 1
        if digits.count % 2 == 1 { digits.append(0) }
        return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
    }
}

// MARK: - Streams

enum StreamCodec {
    static func inflate(_ data: [UInt8]) -> [UInt8]? {
        guard data.count > 2 else { return nil }
        // zlib wrapper: 2-byte header, raw DEFLATE, 4-byte Adler-32.
        let raw = Data(data.dropFirst(2))
        guard let out = try? (raw as NSData).decompressed(using: .zlib) else { return nil }
        return [UInt8](out as Data)
    }

    static func unpredict(_ data: [UInt8], parms: PDFObject?) -> [UInt8]? {
        let predictor = parms?["Predictor"]?.intValue ?? 1
        guard predictor >= 10 else { return predictor == 1 ? data : nil }
        let columns = parms?["Columns"]?.intValue ?? 1
        let rowLen = columns + 1
        var out: [UInt8] = []
        var prev = [UInt8](repeating: 0, count: columns)
        var i = 0
        while i + rowLen <= data.count {
            let tag = data[i]
            var row = Array(data[(i + 1)..<(i + rowLen)])
            for x in 0..<columns {
                let left = x > 0 ? Int(row[x - 1]) : 0
                let up = Int(prev[x])
                let upLeft = x > 0 ? Int(prev[x - 1]) : 0
                let v = Int(row[x])
                switch tag {
                case 0: break
                case 1: row[x] = UInt8((v + left) & 0xFF)
                case 2: row[x] = UInt8((v + up) & 0xFF)
                case 3: row[x] = UInt8((v + (left + up) / 2) & 0xFF)
                case 4:
                    let pa = abs(up - upLeft), pb = abs(left - upLeft), pc = abs(left + up - 2 * upLeft)
                    let pred = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft)
                    row[x] = UInt8((v + pred) & 0xFF)
                default: return nil
                }
            }
            out += row
            prev = row
            i += rowLen
        }
        return out
    }

    static func decode(_ data: [UInt8], dict: PDFObject) -> [UInt8]? {
        var filters: [String] = []
        var parms: [PDFObject?] = []
        switch dict["Filter"] {
        case .name(let n)?: filters = [n]; parms = [dict["DecodeParms"]]
        case .array(let a)?:
            filters = a.compactMap { if case .name(let n) = $0 { return n }; return nil }
            if case .array(let pa)? = dict["DecodeParms"] { parms = pa.map { $0 } } else { parms = filters.map { _ in nil } }
        default: return data
        }
        var out = data
        for (i, f) in filters.enumerated() {
            guard f == "FlateDecode" || f == "Fl" else { return nil }
            guard let inflated = inflate(out) else { return nil }
            let parm = i < parms.count ? parms[i] : nil
            if case .null? = parm { out = inflated; continue }
            guard let un = unpredict(inflated, parms: parm) else { return nil }
            out = un
        }
        return out
    }
}

// MARK: - File structure

struct PDFFile {
    struct Patch { var offset: Int; var bytes: [UInt8] }
    struct Edit { var patches: [Patch]; var appended: [UInt8]; var producer: String }

    enum Location { case direct(offset: Int, gen: Int), compressed(stream: Int, index: Int) }

    struct IndirectObject {
        var number: Int
        var gen: Int
        var value: PDFObject
        var headerOffset: Int          // where "N G obj" starts
        var bodyRange: Range<Int>      // between "obj" and "endobj" (non-stream objects)
        var streamData: Range<Int>?    // raw stream bytes
    }

    let bytes: [UInt8]
    var locations: [Int: Location] = [:]
    var trailer: [(String, PDFObject)] = []
    var lastXref = 0
    var usesXrefStream = false

    init(bytes: [UInt8]) throws {
        guard bytes.count > 8, Array(bytes.prefix(1024)).firstRange(of: Array("%PDF-".utf8)) != nil else { throw ScrubError.notPDF }
        self.bytes = bytes
        try readCrossReference()
        if trailerValue("Encrypt") != nil { throw ScrubError.encrypted }
        guard trailerValue("Root") != nil else { throw ScrubError.malformed("no document catalog") }
    }

    func trailerValue(_ key: String) -> PDFObject? { trailer.first { $0.0 == key }?.1 }

    // MARK: cross-reference

    private mutating func readCrossReference() throws {
        let tailStart = max(0, bytes.count - 4096)
        guard let r = Array(bytes[tailStart...]).lastRange(of: Array("startxref".utf8)) else {
            throw ScrubError.malformed("no startxref")
        }
        var parser = PDFParser(bytes, at: tailStart + r.upperBound)
        parser.skipWhitespace()
        guard let start = Int(parser.readToken()) else { throw ScrubError.malformed("bad startxref") }
        lastXref = start

        var visited = Set<Int>()
        var next: Int? = start
        var first = true
        while let offset = next, offset >= 0, offset < bytes.count, !visited.contains(offset) {
            visited.insert(offset)
            var section: [(String, PDFObject)]
            var p = PDFParser(bytes, at: offset)
            p.skipWhitespace()
            if p.matches("xref", at: p.p) {
                section = try readClassicSection(from: p.p + 4)
                if case .int(let stm)? = section.first(where: { $0.0 == "XRefStm" })?.1, !visited.contains(stm) {
                    visited.insert(stm)
                    _ = try? readXrefStream(at: stm)
                }
            } else {
                section = try readXrefStream(at: p.p)
                if first { usesXrefStream = true }
            }
            for (k, v) in section where !["Prev", "XRefStm", "Type", "W", "Index", "Length", "Filter", "DecodeParms"].contains(k) {
                if !trailer.contains(where: { $0.0 == k }) { trailer.append((k, v)) }
            }
            first = false
            if case .int(let prev)? = section.first(where: { $0.0 == "Prev" })?.1 { next = prev } else { next = nil }
        }
        guard !trailer.isEmpty else { throw ScrubError.malformed("no trailer") }
    }

    private mutating func readClassicSection(from start: Int) throws -> [(String, PDFObject)] {
        var p = PDFParser(bytes, at: start)
        while true {
            p.skipWhitespace()
            if p.matches("trailer", at: p.p) { p.p += 7; break }
            guard let first = Int(p.readToken()) else { throw ScrubError.malformed("bad xref table") }
            p.skipWhitespace()
            guard let count = Int(p.readToken()) else { throw ScrubError.malformed("bad xref table") }
            for i in 0..<count {
                p.skipWhitespace(); let off = Int(p.readToken()) ?? 0
                p.skipWhitespace(); let gen = Int(p.readToken()) ?? 0
                p.skipWhitespace(); let kind = p.readToken()
                let num = first + i
                if locations[num] == nil && kind == "n" { locations[num] = .direct(offset: off, gen: gen) }
            }
        }
        guard case .dict(let pairs) = try p.parse() else { throw ScrubError.malformed("bad trailer") }
        return pairs
    }

    private mutating func readXrefStream(at offset: Int) throws -> [(String, PDFObject)] {
        let obj = try readObject(at: offset)
        guard case .dict(let pairs) = obj.value, let range = obj.streamData,
              let data = StreamCodec.decode(Array(bytes[range]), dict: obj.value),
              case .array(let wArr)? = obj.value["W"] else { throw ScrubError.malformed("unsupported cross-reference stream") }
        let w = wArr.compactMap { $0.intValue }
        guard w.count == 3 else { throw ScrubError.malformed("bad cross-reference stream") }
        var index: [Int] = [0, obj.value["Size"]?.intValue ?? 0]
        if case .array(let idx)? = obj.value["Index"] { index = idx.compactMap { $0.intValue } }
        let entryLen = w[0] + w[1] + w[2]
        var pos = 0
        func field(_ width: Int) -> Int {
            var v = 0
            for _ in 0..<width { v = v << 8 | Int(data[pos]); pos += 1 }
            return v
        }
        var i = 0
        while i + 1 < index.count {
            for n in index[i]..<(index[i] + index[i + 1]) {
                guard pos + entryLen <= data.count else { break }
                let type = w[0] == 0 ? 1 : field(w[0])
                let f2 = field(w[1]), f3 = field(w[2])
                if locations[n] == nil {
                    if type == 1 { locations[n] = .direct(offset: f2, gen: f3) }
                    else if type == 2 { locations[n] = .compressed(stream: f2, index: f3) }
                }
            }
            i += 2
        }
        return pairs
    }

    // MARK: objects

    func readObject(at offset: Int) throws -> IndirectObject {
        var p = PDFParser(bytes, at: offset)
        p.skipWhitespace()
        let header = p.p
        guard let num = Int(p.readToken()) else { throw ScrubError.malformed("bad object header") }
        p.skipWhitespace()
        guard let gen = Int(p.readToken()) else { throw ScrubError.malformed("bad object header") }
        p.skipWhitespace()
        guard p.readToken() == "obj" else { throw ScrubError.malformed("bad object header") }
        let bodyStart = p.p
        let value = try p.parse()
        p.skipWhitespace()
        var stream: Range<Int>?
        if p.matches("stream", at: p.p) {
            var s = p.p + 6
            if s < bytes.count && bytes[s] == 0x0D { s += 1 }
            if s < bytes.count && bytes[s] == 0x0A { s += 1 }
            var length = -1
            if let l = value["Length"]?.intValue { length = l }
            else if case .ref(let n, _)? = value["Length"], let l = try? resolve(n).intValue { length = l }
            if length < 0 || s + length > bytes.count || !PDFParser(bytes, at: s + length).afterWhitespaceMatches("endstream") {
                guard let e = Array(bytes[s..<min(bytes.count, s + 64_000_000)]).firstRange(of: Array("endstream".utf8)) else {
                    throw ScrubError.malformed("unterminated stream")
                }
                var end = s + e.lowerBound
                if end > s && bytes[end - 1] == 0x0A { end -= 1 }
                if end > s && bytes[end - 1] == 0x0D { end -= 1 }
                length = end - s
            }
            stream = s..<(s + length)
            p.p = s + length
            p.skipWhitespace()
            p.p += 9 // endstream
            p.skipWhitespace()
        }
        let bodyEnd = p.p
        guard p.matches("endobj", at: p.p) else { throw ScrubError.malformed("missing endobj") }
        return IndirectObject(number: num, gen: gen, value: value, headerOffset: header,
                              bodyRange: bodyStart..<bodyEnd, streamData: stream)
    }

    /// Locates and parses object `number`. Returns nil if it's inside an object stream
    /// via `compressedValue`.
    func lookup(_ number: Int) throws -> (object: IndirectObject?, value: PDFObject) {
        switch locations[number] {
        case .direct(let offset, _)?:
            if let obj = try? readObject(at: offset), obj.number == number { return (obj, obj.value) }
        case .compressed(let stm, let index)?:
            return (nil, try compressedValue(stream: stm, index: index, number: number))
        case nil: break
        }
        // Fallback: scan for "N G obj".
        let needle = Array("\(number) ".utf8)
        var searchEnd = bytes.count
        while let r = bytes.lastRange(of: needle, before: searchEnd) {
            searchEnd = r.lowerBound
            if r.lowerBound > 0 && PDFParser.isRegular(bytes[r.lowerBound - 1]) { continue }
            if let obj = try? readObject(at: r.lowerBound), obj.number == number { return (obj, obj.value) }
        }
        throw ScrubError.malformed("object \(number) not found")
    }

    func resolve(_ number: Int) throws -> PDFObject { try lookup(number).value }

    private func compressedValue(stream: Int, index: Int, number: Int) throws -> PDFObject {
        guard case .direct(let off, _)? = locations[stream] else { throw ScrubError.malformed("object stream missing") }
        let stm = try readObject(at: off)
        guard let range = stm.streamData, let data = StreamCodec.decode(Array(bytes[range]), dict: stm.value),
              let n = stm.value["N"]?.intValue, let first = stm.value["First"]?.intValue else {
            throw ScrubError.malformed("unsupported object stream")
        }
        var p = PDFParser(data, at: 0)
        for _ in 0..<n {
            p.skipWhitespace(); let num = Int(p.readToken()) ?? -1
            p.skipWhitespace(); let rel = Int(p.readToken()) ?? 0
            if num == number {
                var q = PDFParser(data, at: first + rel)
                return try q.parse()
            }
        }
        throw ScrubError.malformed("object \(number) not in object stream")
    }

    // MARK: editing

    mutating func makeEdit(company: String, now: Date) throws -> Edit {
        var patches: [Patch] = []
        var newObjects: [(number: Int, gen: Int, body: [UInt8])] = []
        var nextNumber = max(trailerValue("Size")?.intValue ?? 0, (locations.keys.max() ?? 0) + 1)
        var infoRef = trailerValue("Info")

        // --- Info dictionary ---
        var oldInfo: [(String, PDFObject)] = []
        var infoObject: IndirectObject?
        var infoNumber: Int?, infoGen = 0
        switch infoRef {
        case .ref(let n, let g)?:
            infoNumber = n; infoGen = g
            if let found = try? lookup(n) {
                infoObject = found.object
                if case .dict(let pairs) = found.value { oldInfo = pairs }
            }
        case .dict(let pairs)?: oldInfo = pairs
        default: break
        }
        let newInfo = PDFFile.rewriteInfo(oldInfo, company: company, now: now)
        let infoText = Array(PDFObject.dict(newInfo).serialized().utf8)

        if let obj = infoObject, obj.streamData == nil, infoText.count + 2 <= obj.bodyRange.count {
            patches.append(Patch(offset: obj.bodyRange.lowerBound, bytes: PDFFile.padded([0x0A] + infoText + [0x0A], to: obj.bodyRange.count)))
        } else {
            if let obj = infoObject, obj.streamData == nil, obj.bodyRange.count >= 6 {
                patches.append(Patch(offset: obj.bodyRange.lowerBound, bytes: PDFFile.padded(Array(" <<>> ".utf8), to: obj.bodyRange.count)))
            }
            var number = nextNumber
            if let existing = infoNumber { number = existing } else { nextNumber += 1 }
            newObjects.append((number, infoGen, infoText))
            infoRef = .ref(number, infoGen)
        }

        // --- XMP metadata stream ---
        if case .ref(let rootNum, _)? = trailerValue("Root"),
           case .ref(let metaNum, _)? = try? resolve(rootNum)["Metadata"],
           let found = try? lookup(metaNum), let meta = found.object, let range = meta.streamData {
            let isFiltered = meta.value["Filter"] != nil
            let raw = Array(bytes[range])
            if let decoded = isFiltered ? StreamCodec.decode(raw, dict: meta.value) : raw,
               let xml = String(bytes: decoded, encoding: .utf8) {
                let edited = Array(XMPEditor.edit(xml, company: company, now: now).utf8)
                if !isFiltered && edited.count <= range.count, meta.value["Length"]?.intValue == range.count {
                    patches.append(Patch(offset: range.lowerBound, bytes: XMPEditor.pad(edited, to: range.count)))
                } else {
                    // Blank the old packet and append a fresh, uncompressed one.
                    patches.append(Patch(offset: range.lowerBound, bytes: [UInt8](repeating: 0x20, count: range.count)))
                    let padded = XMPEditor.pad(edited, to: edited.count + 2048)
                    var dict: [(String, PDFObject)] = []
                    if case .dict(let pairs) = meta.value {
                        dict = pairs.filter { !["Length", "Filter", "DecodeParms", "DL"].contains($0.0) }
                    }
                    dict.append(("Length", .int(padded.count)))
                    let body = Array(PDFObject.dict(dict).serialized().utf8) + Array("\nstream\n".utf8) + padded + Array("\nendstream".utf8)
                    newObjects.append((meta.number, meta.gen, body))
                }
            }
        }

        var producer = company
        if case .string(let b)? = newInfo.first(where: { $0.0 == "Producer" })?.1 { producer = PDFText.decode(b) }

        guard !newObjects.isEmpty else { return Edit(patches: patches, appended: [], producer: producer) }

        // --- Incremental update ---
        var out: [UInt8] = []
        if let last = bytes.last, last != 0x0A && last != 0x0D { out.append(0x0A) }
        var offsets: [(Int, Int, Int)] = [] // number, gen, offset
        for o in newObjects {
            offsets.append((o.number, o.gen, bytes.count + out.count))
            out += Array("\(o.number) \(o.gen) obj\n".utf8) + o.body + Array("\nendobj\n".utf8)
        }
        var newTrailer: [(String, PDFObject)] = []
        for key in ["Root", "ID"] { if let v = trailerValue(key) { newTrailer.append((key, v)) } }
        if let info = infoRef { newTrailer.append(("Info", info)) }
        newTrailer.append(("Prev", .int(lastXref)))
        let xrefOffset = bytes.count + out.count

        if usesXrefStream {
            let xrefNumber = nextNumber
            offsets.append((xrefNumber, 0, xrefOffset))
            offsets.sort { $0.0 < $1.0 }
            var data: [UInt8] = []
            var index: [PDFObject] = []
            for (n, g, off) in offsets {
                index += [.int(n), .int(1)]
                data += [1, UInt8(off >> 24 & 0xFF), UInt8(off >> 16 & 0xFF), UInt8(off >> 8 & 0xFF), UInt8(off & 0xFF),
                         UInt8(g >> 8 & 0xFF), UInt8(g & 0xFF)]
            }
            var dict: [(String, PDFObject)] = [("Type", .name("XRef")), ("Size", .int(xrefNumber + 1))]
            dict += newTrailer
            dict += [("W", .array([.int(1), .int(4), .int(2)])), ("Index", .array(index)), ("Length", .int(data.count))]
            out += Array("\(xrefNumber) 0 obj\n".utf8) + Array(PDFObject.dict(dict).serialized().utf8)
            out += Array("\nstream\n".utf8) + data + Array("\nendstream\nendobj\n".utf8)
        } else {
            offsets.sort { $0.0 < $1.0 }
            var table = "xref\n"
            for (n, g, off) in offsets { table += "\(n) 1\n" + String(format: "%010d %05d n\r\n", off, g) }
            let size = max(nextNumber, (offsets.map { $0.0 }.max() ?? 0) + 1)
            table += "trailer\n" + PDFObject.dict([("Size", .int(size))] + newTrailer).serialized() + "\n"
            out += Array(table.utf8)
        }
        out += Array("startxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return Edit(patches: patches, appended: out, producer: producer)
    }

    static func padded(_ data: [UInt8], to length: Int) -> [UInt8] {
        data + [UInt8](repeating: 0x20, count: max(0, length - data.count))
    }

    static func pdfDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        let tz = TimeZone.current.secondsFromGMT(for: date)
        let sign = tz >= 0 ? "+" : "-"
        return "D:" + f.string(from: date) + String(format: "%@%02d'%02d'", sign, abs(tz) / 3600, abs(tz) % 3600 / 60)
    }

    static func rewriteInfo(_ old: [(String, PDFObject)], company: String, now: Date) -> [(String, PDFObject)] {
        let companyString = PDFObject.string(PDFText.encode(company))
        let replaced: Set<String> = ["Author", "Creator", "Producer"]
        var out: [(String, PDFObject)] = []
        for (key, value) in old {
            if key == "Keywords" { continue }
            if replaced.contains(key) { out.append((key, companyString)); continue }
            if key == "ModDate" { out.append((key, .string(Array(pdfDate(now).utf8)))); continue }
            if case .string(let b) = value {
                let text = PDFText.decode(b)
                let swapped = XMPEditor.replaceCanva(in: text, with: company)
                out.append((key, swapped == text ? value : .string(PDFText.encode(swapped))))
            } else {
                out.append((key, value))
            }
        }
        for key in ["Author", "Creator", "Producer"] where !out.contains(where: { $0.0 == key }) { out.append((key, companyString)) }
        if !out.contains(where: { $0.0 == "ModDate" }) { out.append(("ModDate", .string(Array(pdfDate(now).utf8)))) }
        return out
    }
}

private extension PDFParser {
    func afterWhitespaceMatches(_ keyword: String) -> Bool {
        var q = self
        q.skipWhitespace()
        return q.matches(keyword, at: q.p)
    }
}

// MARK: - XMP

enum XMPEditor {
    static func replaceCanva(in text: String, with company: String) -> String {
        text.replacingOccurrences(of: "\\bcanva\\b", with: NSRegularExpression.escapedTemplate(for: company),
                                  options: [.regularExpression, .caseInsensitive])
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func sub(_ s: NSMutableString, _ pattern: String, _ template: String) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        re.replaceMatches(in: s, options: [], range: NSRange(location: 0, length: s.length), withTemplate: template)
    }

    private static func setProperty(_ s: NSMutableString, _ prop: String, _ value: String) {
        let v = NSRegularExpression.escapedTemplate(for: value)
        let p = NSRegularExpression.escapedPattern(for: prop)
        sub(s, "\\b(\(p)\\s*=\\s*)\"[^\"]*\"", "$1\"\(v)\"")
        sub(s, "\\b(\(p)\\s*=\\s*)'[^']*'", "$1'\(v)'")
        sub(s, "(<\(p)(?:\\s[^>]*)?>)[^<]*(</\(p)>)", "$1\(v)$2")
    }

    private static func removeProperty(_ s: NSMutableString, _ prop: String) {
        let p = NSRegularExpression.escapedPattern(for: prop)
        sub(s, "(?<=\\s)\(p)\\s*=\\s*(\"[^\"]*\"|'[^']*')", "")
        sub(s, "<\(p)(?:\\s[^>]*)?>[\\s\\S]*?</\(p)>", "")
        sub(s, "<\(p)(?:\\s[^>]*)?/>", "")
    }

    static func edit(_ xml: String, company: String, now: Date) -> String {
        let s = NSMutableString(string: xml)
        let c = xmlEscape(company)
        let iso = ISO8601DateFormatter.string(from: now, timeZone: .current,
                                              formatOptions: [.withInternetDateTime])
        setProperty(s, "pdf:Producer", c)
        setProperty(s, "xmp:CreatorTool", c)
        setProperty(s, "xmp:ModifyDate", iso)
        setProperty(s, "xmp:MetadataDate", iso)
        removeProperty(s, "pdf:Keywords")
        removeProperty(s, "dc:subject")
        sub(s, "<dc:creator(\\s[^>]*)?>[\\s\\S]*?</dc:creator>",
            "<dc:creator><rdf:Seq><rdf:li>\(NSRegularExpression.escapedTemplate(for: c))</rdf:li></rdf:Seq></dc:creator>")
        sub(s, "(?i)\\bcanva\\b", NSRegularExpression.escapedTemplate(for: c))
        return s as String
    }

    /// Pads an XMP packet with whitespace (before the closing `<?xpacket end` if present).
    static func pad(_ data: [UInt8], to length: Int) -> [UInt8] {
        let extra = length - data.count
        guard extra > 0 else { return data }
        var padding = [UInt8](repeating: 0x20, count: extra)
        var i = 99
        while i < extra - 1 { padding[i] = 0x0A; i += 100 }
        if extra >= 1 { padding[extra - 1] = 0x0A }
        if let r = data.lastRange(of: Array("<?xpacket end".utf8)) {
            return Array(data[..<r.lowerBound]) + padding + Array(data[r.lowerBound...])
        }
        return data + padding
    }
}

// MARK: - Byte search helpers

extension Array where Element == UInt8 {
    func firstRange(of needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= count else { return nil }
        return withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { n in
                guard let found = memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) else { return nil }
                let start = UnsafeRawPointer(found) - UnsafeRawPointer(hay.baseAddress!)
                return start..<(start + needle.count)
            }
        }
    }

    func lastRange(of needle: [UInt8], before end: Int? = nil) -> Range<Int>? {
        let limit = Swift.min(end ?? count, count)
        guard !needle.isEmpty, needle.count <= limit else { return nil }
        var i = limit - needle.count
        let first = needle[0]
        while i >= 0 {
            if self[i] == first {
                var j = 1
                while j < needle.count && self[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i..<(i + needle.count) }
            }
            i -= 1
        }
        return nil
    }
}
