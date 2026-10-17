import Foundation

/// Use the server's JSON types and scalar values as an independent oracle.
/// Foundation supplies only the paths; it does not convert the numeric values.
enum LabJSONComparison {
    static func paths(_ text: String) throws -> [String] {
        let value=try JSONSerialization.jsonObject(with:Data(text.utf8),options:.fragmentsAllowed)
        func visit(_ value:Any,_ path:String) throws -> [String] {
            var result=[path]
            if let object=value as? [String:Any] {
                for key in object.keys.sorted() {
                    let quoted=String(decoding:try JSONSerialization.data(withJSONObject:key,options:.fragmentsAllowed),as:UTF8.self)
                    result += try visit(object[key]!,path+"."+quoted)
                }
            } else if let array=value as? [Any] {
                for (index,child) in array.enumerated() { result += try visit(child,path+"[\(index)]") }
            }
            return result
        }
        return try visit(value,"$")
    }
    static func scalar(_ type:String,_ hex:String) throws -> String {
        try require(hex != "NULL","JSON comparison path is missing")
        if type == "OBJECT" || type == "ARRAY" { return "" } // Paths retain structure and order.
        if type == "DOUBLE" {
            let text=try decode(hex)
            guard let number=Double(text),number.isFinite else { throw LabError("invalid JSON double in comparison") }
            return String(number.bitPattern,radix:16)
        }
        return hex // Exact strings, integers, decimals, temporal and opaque values.
    }
    static func decode(_ hex:String) throws -> String {
        let bytes=Array(hex.utf8)
        try require(bytes.count % 2 == 0,"invalid JSON comparison hex")
        let data=try stride(from:0,to:bytes.count,by:2).map { index -> UInt8 in
            guard let byte=UInt8(String(decoding:bytes[index..<index+2],as:UTF8.self),radix:16) else { throw LabError("invalid JSON comparison hex") }
            return byte
        }
        guard let text=String(bytes:data,encoding:.utf8) else { throw LabError("invalid JSON comparison UTF-8") }
        return text
    }
}

extension LabFixture {
    func comparisonRows(_ role:LabProfile.Role,table:String,columns:[String],jsonColumns:[String],orderBy:String) throws -> String {
        let expressions=columns.map { "IFNULL(HEX(CAST(`"+$0.replacingOccurrences(of:"`",with:"``")+"` AS BINARY)),'<NULL>')" }.joined(separator:",")
        let from=" FROM "+table+" ORDER BY "+orderBy
        let raw=try sql(role,"SET NAMES utf8mb4; SET time_zone='+00:00'; SELECT "+expressions+from,preserveWhitespace:true)
        guard !raw.isEmpty,!jsonColumns.isEmpty else { return raw }
        return try raw.components(separatedBy:"\n").enumerated().map { row,line in
            var values=line.components(separatedBy:"\t")
            try require(values.count == columns.count,"JSON comparison row width differs")
            for (index,column) in columns.enumerated() where jsonColumns.contains(where: { LabSQLName.equal($0,column) }) && values[index] != "<NULL>" {
                let paths=try LabJSONComparison.paths(LabJSONComparison.decode(values[index]))
                var nodes:[[String]]=[]
                for start in stride(from:0,to:paths.count,by:32) {
                    let part=Array(paths[start..<min(start+32,paths.count)])
                    let selections=part.flatMap { path -> [String] in
                        let hex=path.utf8.map { String(format:"%02x",$0) }.joined()
                        let value="JSON_EXTRACT(`"+column.replacingOccurrences(of:"`",with:"``")+"`,CONVERT(0x"+hex+" USING utf8mb4))"
                        return ["JSON_TYPE("+value+")","HEX(JSON_UNQUOTE("+value+"))"]
                    }
                    let result=try sql(role,"SET NAMES utf8mb4; SET time_zone='+00:00'; SELECT "+selections.joined(separator:",")+from+" LIMIT 1 OFFSET \(row)",preserveWhitespace:true).components(separatedBy:"\t")
                    try require(result.count == part.count*2,"JSON comparison path result differs")
                    for (i,path) in part.enumerated() {
                        let type=result[i*2]
                        nodes.append([path,type,try LabJSONComparison.scalar(type,result[i*2+1])])
                    }
                }
                values[index]=try JSONSerialization.data(withJSONObject:nodes).base64EncodedString()
            }
            return values.joined(separator:"\t")
        }.joined(separator:"\n")
    }
}
