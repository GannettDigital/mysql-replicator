import Foundation
import MySQLNIO
import NIOCore
import ReplicatorCodec

struct JSONSQLValue {
    let sql: String
    let binds: [MySQLData]
}
enum JSONSQL {
    static func scalar(_ s: JSONTypedScalar) -> JSONSQLValue? {
        let cast: String
        switch s.type {
        case 1000: cast="SIGNED"
        case 1001: cast="UNSIGNED"
        case 246: cast="DECIMAL(\(s.precision),\(s.scale))"
        case 10,11,12: return .init(sql:"JSON_EXTRACT(JSON_ARRAY(?),'$[0]')",binds:[temporal(s)])
        case 253: return .init(sql:"JSON_EXTRACT(JSON_ARRAY(CAST(? AS BINARY)),'$[0]')",binds:[.init(type:.blob,buffer:ByteBuffer(bytes:s.rawBytes))])
        default: return nil
        }
        return .init(sql:"JSON_EXTRACT(JSON_ARRAY(CAST(? AS \(cast))),'$[0]')",binds:[.init(string:s.value)])
    }
    static func temporal(_ s:JSONTypedScalar) -> MySQLData {
        let bits=s.rawBytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset*8) }
        let packed=Int64(bitPattern:bits), magnitude=packed.magnitude
        let whole=magnitude >> 24, micros=UInt32(magnitude & 0xffffff)
        var buffer=ByteBufferAllocator().buffer(capacity:12)
        if s.type == 11 {
            let hour=UInt32((whole >> 12)&1023)
            buffer.writeInteger(UInt8(packed < 0 ? 1 : 0))
            buffer.writeInteger(hour/24,endianness:.little)
            buffer.writeInteger(UInt8(hour%24)); buffer.writeInteger(UInt8((whole >> 6)&63)); buffer.writeInteger(UInt8(whole&63))
            buffer.writeInteger(micros,endianness:.little)
            return .init(type:.time,buffer:buffer)
        }
        let ymd=whole >> 17, ym=ymd >> 5
        buffer.writeInteger(UInt16(ym/13),endianness:.little)
        buffer.writeInteger(UInt8(ym%13)); buffer.writeInteger(UInt8(ymd&31))
        if s.type == 10 { return .init(type:.date,buffer:buffer) }
        buffer.writeInteger(UInt8((whole >> 12)&31)); buffer.writeInteger(UInt8((whole >> 6)&63)); buffer.writeInteger(UInt8(whole&63))
        buffer.writeInteger(micros,endianness:.little)
        return .init(type:.datetime,buffer:buffer)
    }
    static func document(_ document: JSONDocument, scalars: [JSONSQLValue]) -> JSONSQLValue {
        precondition(scalars.count == document.typedValues.count)
        var sql="CAST(? AS JSON)",binds=[MySQLData(string:document.text)]
        if !scalars.isEmpty {
            sql="JSON_SET("+sql
            for (typed,scalar) in zip(document.typedValues,scalars) {
                sql += ",?,"+scalar.sql
                binds.append(.init(string:typed.path)); binds += scalar.binds
            }
            sql += ")"
        }
        return .init(sql:sql,binds:binds)
    }
    static func scratchDefinition(_ s:JSONTypedScalar) throws -> (String,MySQLData) {
        switch s.type {
        case 7: return ("TIMESTAMP(6) NULL",.init(string:s.value))
        case 13:
            guard let text=String(data:s.rawBytes,encoding:.ascii),UInt16(text) != nil else { throw ApplyError("invalid JSON YEAR bytes") }
            return ("YEAR NULL",.init(string:text))
        case 16:
            try require((1...8).contains(s.rawBytes.count),"invalid JSON BIT bytes")
            let n=s.rawBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            var bytes=ByteBufferAllocator().buffer(capacity:8); bytes.writeInteger(n,endianness:.little)
            return ("BIT(\(s.rawBytes.count*8)) NULL",.init(type:.longlong,buffer:bytes,isUnsigned:true))
        case 249,250,251,252:
            let name=[249:"TINYBLOB",250:"MEDIUMBLOB",251:"LONGBLOB",252:"BLOB"][s.type]!
            return (name+" NULL",.init(type:.blob,buffer:ByteBuffer(bytes:s.rawBytes)))
        case 15,254:
            let size=s.rawBytes.count
            try require(s.type == 15 ? (1...65532).contains(size) : size <= 255,"target SQL cannot recreate this JSON binary field width")
            return ((s.type == 15 ? "VARBINARY" : "BINARY")+"(\(size)) NULL",.init(type:.blob,buffer:ByteBuffer(bytes:s.rawBytes)))
        default: throw ApplyError("target SQL has no exact constructor for JSON opaque type \(s.type); original bytes remain in relay and recovery output")
        }
    }
}

extension TargetSession {
    /// Temporary tables preserve SQL field types that CAST cannot produce,
    /// including TIMESTAMP and the four BLOB widths. They hold no durable state.
    func resetJSONScratch() throws {
        for name in jsonScratchTables { _ = try query("DROP TEMPORARY TABLE "+name,textProtocol:true) }
        jsonScratchTables.removeAll(); jsonScratchOrdinal=0
    }
    func prepareJSONScratch(_ group:PreparedDMLGroup) throws {
        try resetJSONScratch()
        for mutation in group.mutations {
            guard let after=mutation.row.after else { continue }
            for (column,value) in zip(mutation.table.columns,after) where !column.isGenerated {
                guard case .json(let document)=value else { continue }
                for entry in document.typedValues where JSONSQL.scalar(entry.scalar) == nil {
                    jsonScratchOrdinal += 1
                    _ = try createJSONScratch(entry.scalar,database:mutation.table.database,ordinal:jsonScratchOrdinal)
                }
            }
        }
        jsonScratchOrdinal=0
    }
    private func createJSONScratch(_ s:JSONTypedScalar,database:String,ordinal:UInt64) throws -> String {
        let (definition,_)=try JSONSQL.scratchDefinition(s)
        let name=try quoted(database)+"."+quoted("_replicator_json_"+jsonScratchID+"_\(ordinal)")
        if !jsonScratchTables.contains(name) {
            _ = try query("CREATE TEMPORARY TABLE "+name+" (id BIGINT UNSIGNED PRIMARY KEY,v "+definition+") ENGINE=InnoDB",textProtocol:true)
            jsonScratchTables.insert(name)
        }
        return name
    }
    private func stageJSONScalar(_ s:JSONTypedScalar,database:String) throws -> JSONSQLValue {
        let (_,bind)=try JSONSQL.scratchDefinition(s)
        jsonScratchOrdinal += 1
        let name=try quoted(database)+"."+quoted("_replicator_json_"+jsonScratchID+"_\(jsonScratchOrdinal)")
        if contract.transactional { try require(jsonScratchTables.contains(name),"JSON scratch table must be created before BEGIN") }
        else { _ = try createJSONScratch(s,database:database,ordinal:jsonScratchOrdinal) }
        _ = try query("INSERT INTO "+name+" (id,v) VALUES (1,?)",[bind])
        return .init(sql:"(SELECT JSON_EXTRACT(JSON_ARRAY(v),'$[0]') FROM "+name+" WHERE id=1)",binds:[])
    }
    func prepareJSONValue(_ value:DecodedValue,database:String) throws -> JSONSQLValue {
        guard case .json(let document)=value else { return .init(sql:"?",binds:[try bind(value)]) }
        let scalars=try document.typedValues.map { entry -> JSONSQLValue in
            let scalar=entry.scalar
            let expression=try JSONSQL.scalar(scalar) ?? stageJSONScalar(scalar,database:database)
            // Cast syntax has stable INTEGER/DECIMAL semantics. Check temporal
            // and binary values on this target before issuing the business write.
            if scalar.type < 1000 && scalar.type != 246 {
                let rows=try query("SELECT JSON_TYPE(j) AS t,JSON_UNQUOTE(j) AS v FROM (SELECT "+expression.sql+" AS j LIMIT 1) AS verified",expression.binds).0
                let type=rows.first?.column("t")?.string, text=rows.first?.column("v")?.string
                try require(type == scalar.typeName && text?.utf8.elementsEqual(scalar.display.utf8) == true,"target SQL cannot preserve JSON type \(scalar.type) at \(entry.path): expected \(scalar.typeName), got \(type ?? "SQL NULL")")
            }
            return expression
        }
        return JSONSQL.document(document,scalars:scalars)
    }
    func verifyJSONTypes(_ document:JSONDocument,column:String,table:ApplyTable,key:[DecodedValue]) throws {
        let predicate=try table.primaryKeyColumns.map { try quoted($0)+"=?" }.joined(separator:" AND ")
        let name=try quoted(column),sqlName=try table.sqlName
        let checks=document.scalarChecks
        // Bound SELECT width and parameter count. Strings in JSON paths remain binds.
        for start in stride(from:0,to:checks.count,by:64) {
            let part=Array(checks[start..<min(start+64,checks.count)])
            let select=part.indices.map { "JSON_TYPE(JSON_EXTRACT(\(name),?)) AS j\($0)" }.joined(separator:",")
            let binds=part.map { MySQLData(string:$0.path) }+(try key.map(bind))
            let row=try query("SELECT "+select+" FROM "+sqlName+" WHERE "+predicate,binds).0.first
            for (i,check) in part.enumerated() {
                try require(row?.column("j\(i)")?.string == check.type,"target JSON type differs at \(column)\(check.path)")
            }
        }
    }
}
