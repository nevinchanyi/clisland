import Foundation

/// Order-preserving JSON value, so rewritten config files keep the user's key order.
public indirect enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([Member])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSON
        public init(_ key: String, _ value: JSON) { self.key = key; self.value = value }
    }

    // MARK: Accessors

    public subscript(key: String) -> JSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.last(where: { $0.key == key })?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let i = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[i].value = newValue } else { members.remove(at: i) }
            } else if let newValue {
                members.append(Member(key, newValue))
            }
            self = .object(members)
        }
    }

    public subscript(index: Int) -> JSON? {
        guard case .array(let a) = self, index >= 0, index < a.count else { return nil }
        return a[index]
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var members: [Member]? { if case .object(let m) = self { return m }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    public static func obj(_ pairs: [(String, JSON?)]) -> JSON {
        .object(pairs.compactMap { k, v in v.map { Member(k, $0) } })
    }

    public static func str(_ s: String?) -> JSON? { s.map { .string($0) } }
    public static func num(_ d: Double?) -> JSON? { d.map { .number($0) } }
    public static func strings(_ a: [String]) -> JSON { .array(a.map { .string($0) }) }

    // MARK: Parse

    public static func parse(_ data: Data) -> JSON? {
        var p = Parser(bytes: [UInt8](data))
        p.skipWS()
        guard let v = p.value() else { return nil }
        p.skipWS()
        return p.i == p.bytes.count ? v : nil
    }

    public static func parse(_ text: String) -> JSON? { parse(Data(text.utf8)) }

    // MARK: Serialize

    public func serialized(pretty: Bool = false) -> String {
        var out = ""
        write(into: &out, pretty: pretty, indent: 0)
        return out
    }

    public var data: Data { Data(serialized().utf8) }

    private func write(into out: inout String, pretty: Bool, indent: Int) {
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let closePad = pretty ? String(repeating: "  ", count: indent) : ""
        let nl = pretty ? "\n" : ""
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let d): out += JSON.format(d)
        case .string(let s): JSON.escape(s, into: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (i, v) in a.enumerated() {
                out += pad
                v.write(into: &out, pretty: pretty, indent: indent + 1)
                if i < a.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "]"
        case .object(let m):
            if m.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (i, member) in m.enumerated() {
                out += pad
                JSON.escape(member.key, into: &out)
                out += pretty ? ": " : ":"
                member.value.write(into: &out, pretty: pretty, indent: indent + 1)
                if i < m.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "}"
        }
    }

    static func format(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    static func escape(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    // MARK: Parser

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWS() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        mutating func value() -> JSON? {
            skipWS()
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string().map { .string($0) }
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ v: JSON) -> JSON? {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { return nil }
            i += w.count
            return v
        }

        mutating func number() -> JSON? {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start, let s = String(bytes: bytes[start..<i], encoding: .ascii), let d = Double(s) else { return nil }
            return .number(d)
        }

        mutating func string() -> String? {
            guard bytes[i] == UInt8(ascii: "\"") else { return nil }
            i += 1
            var buf = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: buf, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { return nil }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "n"): buf.append(0x0A)
                    case UInt8(ascii: "t"): buf.append(0x09)
                    case UInt8(ascii: "r"): buf.append(0x0D)
                    case UInt8(ascii: "b"): buf.append(0x08)
                    case UInt8(ascii: "f"): buf.append(0x0C)
                    case UInt8(ascii: "u"):
                        guard var code = hex4() else { return nil }
                        if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count,
                           bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            guard let low = hex4() else { return nil }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                        buf.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: buf.append(e)
                    }
                } else {
                    buf.append(c)
                    i += 1
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<i + 4], encoding: .ascii),
                  let v = UInt32(s, radix: 16) else { return nil }
            i += 4
            return v
        }

        mutating func array() -> JSON? {
            i += 1
            var out = [JSON]()
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
            while true {
                guard let v = value() else { return nil }
                out.append(v)
                skipWS()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
                return nil
            }
        }

        mutating func object() -> JSON? {
            i += 1
            var out = [Member]()
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
            while true {
                skipWS()
                guard i < bytes.count, let k = string() else { return nil }
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let v = value() else { return nil }
                out.append(Member(k, v))
                skipWS()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
                return nil
            }
        }
    }
}
