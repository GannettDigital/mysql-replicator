import Foundation

/// MySQL's system-charset comparison for column and index references. Table
/// names use SQLNameKey and the server's lower_case_table_names contract instead.
enum SQLIdentifier {
    private static func lower(_ scalar: UnicodeScalar) -> UInt32 {
        let value = scalar.value
        if value < 128 { return (65...90).contains(value) ? value + 32 : value }
        return NativeIdentifierLowercase.map[value] ?? value
    }
    static func lowercase(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { UnicodeScalar(lower($0))! }))
    }
    static func key(_ name: String) -> SQLNameKey { SQLNameKey(lowercase(name)) }
    static func equal(_ a: String, _ b: String) -> Bool {
        if a.utf8.elementsEqual(b.utf8) { return true }
        return a.unicodeScalars.lazy.map(lower).elementsEqual(b.unicodeScalars.lazy.map(lower))
    }
    static func equal(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
    }
    static func contains(_ names: [String], _ name: String) -> Bool {
        names.contains { equal($0, name) }
    }
    /// Native IDENT_sys converts utf8mb4 names to the utf8mb3 system charset.
    /// The server stores '?' for each supplementary scalar and emits a warning.
    /// This is the name created by the unchanged source SQL, not a SQL rewrite.
    static func storedName(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value > 0xffff ? UnicodeScalar(63)! : $0 }))
    }
    /// SQL keywords are ASCII. Unicode uppercase conversion can turn an object
    /// name such as `ſelect` into a keyword that the native lexer does not see.
    static func keyword(_ text: String) -> String {
        text.utf8.allSatisfy { $0 < 128 } ? text.uppercased() : ""
    }
}
