import Foundation

/// A document path used for exact SQL row matching. Container sizes prevent
/// extra members from matching. Typed scalar text retains its source subtype.
public struct JSONMatchField {
    public let path: String
    public let type: String
    public let text: String?
    public let count: Int?
    public let floating: Bool
}
extension JSONDocument {
    public func matchFields() throws -> [JSONMatchField] {
        var result:[JSONMatchField]=[]
        try root.walk(path:"$",depth:1) { node,path in
            let type:String, text:String?, count:Int?, floating:Bool
            switch node {
            case .array(let values): type="ARRAY";text=nil;count=values.count;floating=false
            case .object(let values): type="OBJECT";text=nil;count=values.count;floating=false
            case .null: type="NULL";text=nil;count=nil;floating=false
            case .bool(let value): type="BOOLEAN";text=value ? "true" : "false";count=nil;floating=false
            case .string(let value): type="STRING";text=value;count=nil;floating=false
            case .number(let value): type=node.typeName!;text=value;count=nil;floating=type == "DOUBLE"
            case .typed(let value): type=value.typeName;text=value.display;count=nil;floating=false
            }
            result.append(.init(path:path,type:type,text:text,count:count,floating:floating))
        }
        return result
    }
}
