import Foundation

/// Preserve SQL bytes through stdin. A request can contain a routine body;
/// a script lets the mysql client split statements and handle DELIMITER commands.
struct LabSQLInput {
    let arguments: [String]
    let bytes: Data

    init(
        _ text: String, resetGTID: Bool, script: Bool,
        delimiter: String = "_r_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
    ) throws {
        let reset = "SET @@SESSION.GTID_NEXT = 'AUTOMATIC'"
        if script {
            arguments = []
            bytes = Data(((resetGTID ? reset + ";\n" : "") + text + "\n").utf8)
        } else {
            // mysql stores its delimiter in a 16-byte buffer, including NUL.
            try require(
                !delimiter.isEmpty && delimiter.utf8.count <= 15, "SQL delimiter exceeds the mysql client limit")
            try require(!text.contains(delimiter), "SQL contains its test-client delimiter")
            let vertical = text.hasSuffix("\\G")
            let sql = vertical ? String(text.dropLast(2)) : text
            arguments = ["--delimiter=" + delimiter] + (vertical ? ["--vertical"] : [])
            let end = "\n" + delimiter + "\n"
            bytes = Data(((resetGTID ? reset + end : "") + sql + end).utf8)
        }
    }
}
