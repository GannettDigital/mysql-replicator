import Foundation

/// Narrow parser for mysqlbinlog's verbose output for the known poc.items schema:
/// INT, unescaped printable ASCII VARCHAR, BIGINT UNSIGNED. This is independent
/// harness normalization, not the production decoder or a generic SQL parser.
public enum BinlogReference {
    public static func parse(_ text: String, from start: UInt64, before end: UInt64 = .max) throws -> [RowOperation] {
        var position: UInt64 = 0
        var kind: String?
        var before: [Int: String] = [:], after: [Int: String] = [:]
        var section = ""
        var result: [RowOperation] = []
        let quote = String(UnicodeScalar(96)!)
        let table = quote + "poc" + quote + "." + quote + "items" + quote
        func row(_ values: [Int: String]) throws -> [String]? {
            if values.isEmpty { return nil }
            try require(values.count == 3 && values.keys.sorted() == [1, 2, 3], "incomplete or unexpected row image")
            return [values[1]!, values[2]!, values[3]!]
        }
        func flush() throws {
            if let operation = kind {
                let b = try row(before), a = try row(after)
                try require((operation == "insert" && b == nil && a != nil) ||
                            (operation == "delete" && b != nil && a == nil) ||
                            (operation == "update" && b != nil && a != nil), "invalid row sections")
                result.append(RowOperation(operation, before: b, after: a))
            }
            kind = nil; before = [:]; after = [:]; section = ""
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("# at ") {
                try flush()
                guard let offset = UInt64(line.dropFirst(5)) else { throw LabError("invalid event position") }
                position = offset
            } else if line.hasPrefix("### INSERT INTO ") || line.hasPrefix("### UPDATE ") || line.hasPrefix("### DELETE FROM ") {
                try flush()
                guard position >= start && position < end else { continue }
                try require(line.hasSuffix(table), "unexpected application table in reference range")
                kind = line.hasPrefix("### INSERT") ? "insert" : line.hasPrefix("### UPDATE") ? "update" : "delete"
            } else if line == "### WHERE" { section = "before" }
            else if line == "### SET" { section = "after" }
            else if line.hasPrefix("###   @"), kind != nil {
                guard let equal = line.firstIndex(of: "="),
                      let index = Int(line[line.index(line.startIndex, offsetBy: 7)..<equal]),
                      let metadata = line.range(of: " /*", options: .backwards) else {
                    throw LabError("invalid mysqlbinlog column")
                }
                let raw = String(line[line.index(after: equal)..<metadata.lowerBound])
                let value: String
                switch index {
                case 1:
                    try require(Int32(raw) != nil, "invalid signed key")
                    value = raw
                case 2:
                    try require(raw.hasPrefix("'") && raw.hasSuffix("'"), "invalid text")
                    value = String(raw.dropFirst().dropLast())
                    try require(value.unicodeScalars.allSatisfy { (32...126).contains($0.value) && $0.value != 39 && $0.value != 92 }, "text outside reference fixture grammar")
                case 3:
                    // mysqlbinlog prints high unsigned integers as signed (unsigned).
                    if let paren = raw.firstIndex(of: "("), raw.hasSuffix(")") {
                        let signed = String(raw[..<paren]).trimmingCharacters(in: .whitespaces)
                        let unsigned = String(raw[raw.index(after: paren)..<raw.index(before: raw.endIndex)])
                        guard let signedValue = Int64(signed), let unsignedValue = UInt64(unsigned),
                              UInt64(bitPattern: signedValue) == unsignedValue else {
                            throw LabError("inconsistent unsigned rendering")
                        }
                        value = unsigned
                    } else {
                        try require(UInt64(raw) != nil, "invalid unsigned quantity")
                        value = raw
                    }
                default: throw LabError("unknown fixture column")
                }
                if section == "before" {
                    try require(before[index] == nil, "duplicate before column"); before[index] = value
                } else if section == "after" {
                    try require(after[index] == nil, "duplicate after column"); after[index] = value
                } else { throw LabError("column outside a row section") }
            } else if line.hasPrefix("###"), position >= start && position < end {
                throw LabError("unrecognized row output")
            }
        }
        try flush()
        return result
    }
}
