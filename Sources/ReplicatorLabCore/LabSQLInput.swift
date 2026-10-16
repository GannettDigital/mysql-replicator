import Foundation

/// Preserve SQL bytes through stdin. A request can contain a routine body;
/// a script lets the mysql client split statements and handle DELIMITER commands.
struct LabSQLInput {
    let arguments: [String]
    let bytes: Data

    init(
        _ text: String, resetGTID: Bool, script: Bool,
        delimiter: String = "_r_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    ) throws {
        let reset = "SET @@SESSION.GTID_NEXT = 'AUTOMATIC'"
        if script {
            arguments = []
            bytes = Data(((resetGTID ? reset + ";\n" : "") + text + "\n").utf8)
        } else {
            try require(!text.contains(delimiter), "SQL contains its test-client delimiter")
            let vertical = text.hasSuffix("\\G")
            let sql = vertical ? String(text.dropLast(2)) : text
            arguments = ["--delimiter=" + delimiter] + (vertical ? ["--vertical"] : [])
            let end = "\n" + delimiter + "\n"
            bytes = Data(((resetGTID ? reset + end : "") + sql + end).utf8)
        }
    }
}
