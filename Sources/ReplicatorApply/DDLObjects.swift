import Foundation
import ReplicatorCodec

extension DDLParser {
    /// Only the header is interpreted here. MySQL parses the complete view or
    /// stored-program definition; its body is never executed during creation.
    mutating func objectStatement() throws -> DDLStatement? {
        let saved = index
        guard take("CREATE") || take("ALTER") || take("DROP") else { return nil }
        let verb = tokens[saved].keyword
        var replace = false
        if take("OR") { try expect("REPLACE"); replace = true }
        while index < tokens.count {
            if take("ALGORITHM") { _ = take("="); try require(["UNDEFINED","MERGE","TEMPTABLE"].contains(try identifier().uppercased()),"unsupported view algorithm") }
            else if take("DEFINER") {
                try expect("=")
                if take("CURRENT_USER") { if take("(") { try expect(")") } }
                else {
                    try accountPart(); try expect("@"); try accountPart()
                }
            } else if take("SQL") { try expect("SECURITY"); try require(take("DEFINER") || take("INVOKER"),"invalid SQL SECURITY") }
            else { break }
        }
        if take("TRIGGER") { throw ProhibitedDDL.trigger }
        if take("EVENT") { throw ProhibitedDDL.event }
        guard index < tokens.count, let kind = ObjectDDL.Kind(rawValue:tokens[index].keyword) else { index = saved; return nil }
        index += 1
        try require(!replace || (verb == "CREATE" && kind == .view),"OR REPLACE is supported only for views")
        var conditional = false
        if verb == "DROP" && take("IF") { try expect("EXISTS"); conditional = true }
        let name = try name()
        let operation: ObjectDDL.Operation = verb == "DROP" ? .drop : verb == "ALTER" ? .alter : replace ? .replace : .create
        if operation == .drop {
            if kind == .view { _ = take("RESTRICT") || take("CASCADE") }; try end()
        } else if kind == .view {
            if isNext("(") { _ = try parenthesized() }
            try expect("AS"); try expect("SELECT")
            try require(index < tokens.count,"empty view SELECT")
            // A view is not a compound stored program; semicolons must end it.
            if tokens.last?.keyword == ";" { tokens.removeLast() }
            try require(!tokens[index...].contains{$0.keyword == ";"},"multiple statements in view DDL")
            index = tokens.count
        } else {
            try require(operation == .create,"only CREATE/DROP stored routines are supported")
            _ = try parenthesized() // Also rules out loadable FUNCTION ... SONAME.
            if kind == .function { try expect("RETURNS") }
            try require(index < tokens.count,"missing stored routine body")
            // Semicolons inside BEGIN/END are part of a single CREATE query.
            // CLIENT_MULTI_STATEMENTS is not negotiated by our target driver.
            index = tokens.count
        }
        return .object(ObjectDDL(kind:kind,operation:operation,name:name,ifExists:conditional))
    }
    private mutating func accountPart() throws {
        if index < tokens.count && tokens[index].literal != nil { index += 1 }
        else { _ = try identifier() }
    }
}

extension TargetSession {
    func objectExists(_ object: ObjectDDL) throws -> Bool {
        let sql: String
        switch object.kind {
        case .view: sql = "SELECT COUNT(*) AS v FROM information_schema.VIEWS WHERE TABLE_SCHEMA=? AND TABLE_NAME=?"
        case .function,.procedure: sql = "SELECT COUNT(*) AS v FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=? AND ROUTINE_NAME=? AND ROUTINE_TYPE='\(object.kind.rawValue)'"
        }
        return try scalar(sql,[.init(string:object.name.database),.init(string:object.name.table)]) != "0"
    }
    func prepareObjectDDL(_ statement: DDLStatement,object: ObjectDDL,source: QueryControl,context: QuerySessionContext) throws -> PreparedDDL {
        let exists = try objectExists(object)
        if object.kind == .view {
            // CREATE OR REPLACE must never displace a base table/history entry.
            try require(discovered[object.name.identity] == nil,"view DDL conflicts with a discovered base table")
            if try tableExists(object.name) { try require(exists,"view DDL target is a base table") }
        }
        switch object.operation {
        case .create: try require(!exists,"DDL object already exists")
        case .alter: try require(exists,"DDL object is absent")
        case .drop: try require(exists || object.ifExists,"DDL object is absent")
        case .replace: break
        }
        try setDDLSession(context,source:source)
        return PreparedDDL(statement:statement,before:nil,after:nil,sql:String(decoding:source.sql,as:UTF8.self))
    }
}
