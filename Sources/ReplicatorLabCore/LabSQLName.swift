import Foundation

/// Independent test helpers. Do not use Swift canonical equality for names or
/// values read from MySQL. Do not reuse the applier's parser as a test oracle.
enum LabSQLName {
    static func equal(_ a:String,_ b:String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func quote(_ name:String) -> String { "`"+name.replacingOccurrences(of:"`",with:"``")+"`" }
    static func literal(_ name:String) -> String {
        "CONVERT(0x"+name.utf8.map { String(format:"%02X",$0) }.joined()+" USING utf8mb4)"
    }
}
