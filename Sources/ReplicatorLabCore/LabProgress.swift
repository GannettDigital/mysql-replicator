import Foundation

/// Poll only newline-terminated progress records. A live read can observe a
/// prefix of the next JSON object, even when the writer emits one record at once.
enum LabProgress {
    static func latest(in data: Data) throws -> [String:Any]? {
        guard let end=data.lastIndex(of:10),
              let line=data[..<end].split(separator:10).last else { return nil }
        // Completed malformed records remain errors; only the unfinished tail
        // is ignored so polling cannot hide a broken logging contract.
        return try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any]
    }
}
