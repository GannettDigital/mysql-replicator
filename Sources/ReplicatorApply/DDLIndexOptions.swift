import MySQLSyntax

struct ParsedIndexOptions { var parser:String?; var visible:Bool? }

extension DDLParser {
    mutating func ddlOption() throws -> SQLDDLOption {
        do {
            guard let option=try SQLDDLOption.parseNext(tokens,index:&index) else { throw ApplyError("expected DDL option") }
            return option
        } catch let error as SQLSyntaxError { throw ApplyError(error.message) }
    }
    mutating func indexType() throws {
        guard isNext("USING") || isNext("TYPE") else { return }
        guard case .indexType(let type)=try ddlOption() else { throw ApplyError("expected index type") }
        // InnoDB and MyISAM normalize HASH requests to BTREE. RTREE is not
        // an ordinary index on these engines. The target checks its own limits.
        try require(type == "BTREE" || type == "HASH","RTREE requires a native spatial index")
    }
    mutating func indexOptions(fulltext:Bool = false,spatial:Bool = false,primary:Bool = false) throws -> ParsedIndexOptions {
        var parser:String?,visible:Bool?
        while ["USING","TYPE","COMMENT","KEY_BLOCK_SIZE","WITH","VISIBLE","INVISIBLE"].contains(where:isNext) {
            if isNext("VISIBLE") || isNext("INVISIBLE") {
                try require(targetVersion != "5.7.","target MySQL 5.7 does not support index visibility")
                visible=take("INVISIBLE") ? false : nil
                if visible == nil {try expect("VISIBLE")}
                try require(!primary || visible != false,"PRIMARY KEY cannot be invisible")
                continue
            }
            if isNext("USING") || isNext("TYPE") {
                try require(!fulltext && !spatial,"index type is not allowed on SPATIAL/FULLTEXT indexes")
                try indexType();continue
            }
            switch try ddlOption() {
            case .parser(let name):try require(fulltext,"WITH PARSER requires FULLTEXT");parser=SQLIdentifier.lowercase(name)
            case .comment,.keyBlockSize:break // Original SQL retains physical options.
            default:throw ApplyError("unexpected index option")
            }
        }
        return .init(parser:parser,visible:visible)
    }
    mutating func executionOption() throws {
        switch try ddlOption() {
        case .algorithm(let name):
            try require(name != "INSTANT" || targetVersion != "5.7.","target MySQL 5.7 does not support ALGORITHM=INSTANT")
        case .lock:break
        default:throw ApplyError("expected ALGORITHM or LOCK")
        }
    }
    mutating func executionOptions() throws {
        while isNext("ALGORITHM") || isNext("LOCK") { try executionOption() }
    }
    func inlineUnique(_ column:ApplyColumn) -> ApplyIndex {
        ApplyIndex(name:column.name,unique:true,parts:[ApplyIndexPart(column:column.name,prefix:nil)],implicitName:true,implicitNameByteLimit:targetVersion == "5.7." ? nil : 61)
    }
}
