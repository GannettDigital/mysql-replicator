import Foundation

/// One declaration drives execution and offline catalog binding checks.
/// Source locations point to these scenario definitions.
enum DDLCoverageCases {
    struct DDLChange {
        let test: QualificationCase
        let sql, table, schema, rows, collation: String
        init(_ id: String, _ name: String, _ sql: String, _ table: String, _ schema: String,
             _ rows: String, _ collation: String, file: String = #filePath, line: UInt = #line) {
            test = QualificationCase(id, name, file: file, line: line)
            self.sql = sql; self.table = table; self.schema = schema
            self.rows = rows; self.collation = collation
        }
    }

    static let positive = QualificationCase("positive", "Replicate INSERT, UPDATE and DELETE; compare rows, binlogs and SQLite checkpoints")
    static let group = QualificationCase("ddl", "Apply ordered DDL and DML; verify schema history, unchanged SQL and binlog order")
    static let unsupported = QualificationCase("ddl-unsupported", "Reject unsupported DECIMAL column before target mutation or checkpoint advance")
    static let denied = QualificationCase("ddl-denied", "Keep a pending DDL intent and stop when target CREATE permission is denied")

    static let changes: [DDLChange] = [
        .init("create-local-engine", "CREATE without ENGINE uses each server default", "CREATE TABLE poc.changes(payload VARBINARY(10) NULL,id INT PRIMARY KEY)","changes","payload:varbinary:YES,id:int:NO","",""),
        .init("insert-binary", "INSERT preserves binary bytes in the new table", "INSERT INTO poc.changes VALUES(0x00FF,1)","changes","payload:varbinary:YES,id:int:NO","1\t00FF",""),
        .init("add-column-first", "ADD nullable VARCHAR FIRST inherits the table charset and collation", "ALTER TABLE poc.changes ADD note VARCHAR(20) NULL FIRST","changes","note:varchar:YES,payload:varbinary:YES,id:int:NO","1\tNULL\t00FF","utf8mb4_unicode_ci"),
        .init("update-added-column", "UPDATE writes the newly added first column", "UPDATE poc.changes SET note='first' WHERE id=1","changes","note:varchar:YES,payload:varbinary:YES,id:int:NO","1\t6669727374\t00FF","utf8mb4_unicode_ci"),
        .init("drop-payload-column", "DROP COLUMN preserves remaining values and column order", "ALTER TABLE poc.changes DROP COLUMN payload","changes","note:varchar:YES,id:int:NO","1\t6669727374","utf8mb4_unicode_ci"),
        .init("update-primary-key", "UPDATE changes the primary key after dropping a column", "UPDATE poc.changes SET note='next',id=2 WHERE id=1","changes","note:varchar:YES,id:int:NO","2\t6E657874","utf8mb4_unicode_ci"),
        .init("rename-table", "RENAME preserves data and removes the old table name", "RENAME TABLE poc.changes TO poc.renamed","renamed","note:varchar:YES,id:int:NO","2\t6E657874","utf8mb4_unicode_ci"),
        .init("insert-after-rename", "INSERT NULL uses the renamed table schema", "INSERT INTO poc.renamed VALUES(NULL,3)","renamed","note:varchar:YES,id:int:NO","2\t6E657874\n3\tNULL","utf8mb4_unicode_ci"),
        .init("drop-renamed-table", "DROP removes the renamed table", "DROP TABLE poc.renamed","renamed","","",""),
        .init("recreate-default-engine", "Recreate a dropped table with quoted DEFAULT engine and unsigned BIGINT key", "CREATE TABLE poc.renamed(id BIGINT UNSIGNED PRIMARY KEY,b VARBINARY(10) NULL) ENGINE='DEFAULT'","renamed","id:bigint:NO,b:varbinary:YES","",""),
        .init("insert-unsigned-maximum", "INSERT preserves the maximum unsigned BIGINT key and binary payload", "INSERT INTO poc.renamed VALUES(18446744073709551615,0xCAFE)","renamed","id:bigint:NO,b:varbinary:YES","18446744073709551615\tCAFE",""),
        .init("truncate-nonempty-table", "TRUNCATE empties a populated table while retaining its schema", "TRUNCATE TABLE poc.renamed","renamed","id:bigint:NO,b:varbinary:YES","",""),
        .init("insert-after-truncate", "INSERT reuses the same primary key after TRUNCATE", "INSERT INTO poc.renamed VALUES(18446744073709551615,0xCAFE)","renamed","id:bigint:NO,b:varbinary:YES","18446744073709551615\tCAFE",""),
        .init("update-binary-null", "UPDATE sets the binary payload to NULL", "UPDATE poc.renamed SET b=NULL WHERE id=18446744073709551615","renamed","id:bigint:NO,b:varbinary:YES","18446744073709551615\tNULL",""),
        .init("delete-unsigned-maximum", "DELETE finds the maximum unsigned BIGINT primary key", "DELETE FROM poc.renamed WHERE id=18446744073709551615","renamed","id:bigint:NO,b:varbinary:YES","",""),
        .init("drop-recreated-table", "DROP removes the recreated table", "DROP TABLE poc.renamed","renamed","","",""),
        .init("create-explicit-collation", "CREATE preserves explicit table defaults and a COLLATE-only column", "CREATE TABLE poc.changes(payload VARBINARY(10) NULL,id INT PRIMARY KEY,note VARCHAR(20) COLLATE utf8mb4_bin) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci","changes","payload:varbinary:YES,id:int:NO,note:varchar:YES","","utf8mb4_bin"),
        .init("insert-explicit-collation", "INSERT preserves text and binary values under explicit collation", "INSERT INTO poc.changes VALUES(0x00FF,1,'last')","changes","payload:varbinary:YES,id:int:NO,note:varchar:YES","1\t6C617374\t00FF","utf8mb4_bin"),
        .init("update-explicit-collation", "UPDATE text uses the explicitly collated column", "UPDATE poc.changes SET note='done' WHERE id=1","changes","payload:varbinary:YES,id:int:NO,note:varchar:YES","1\t646F6E65\t00FF","utf8mb4_bin"),
        .init("delete-explicit-collation", "DELETE removes the row from the explicitly collated table", "DELETE FROM poc.changes WHERE id=1","changes","payload:varbinary:YES,id:int:NO,note:varchar:YES","","utf8mb4_bin"),
        .init("drop-explicit-collation", "DROP removes the table with explicit collation", "DROP TABLE poc.changes","changes","","",""),
        .init("create-charset-only", "CREATE with CHARACTER SET uses the logged compatible default collation", "CREATE TABLE poc.defaults(id INT PRIMARY KEY,note VARCHAR(20) CHARACTER SET utf8mb4)","defaults","id:int:NO,note:varchar:YES","","utf8mb4_general_ci"),
        .init("insert-charset-only", "INSERT text into a column created with CHARACTER SET only", "INSERT INTO poc.defaults VALUES(1,'charset')","defaults","id:int:NO,note:varchar:YES","1\t63686172736574","utf8mb4_general_ci"),
        .init("update-charset-only", "UPDATE text in the column using the logged default collation", "UPDATE poc.defaults SET note='checked' WHERE id=1","defaults","id:int:NO,note:varchar:YES","1\t636865636B6564","utf8mb4_general_ci"),
        .init("delete-charset-only", "DELETE the row from the charset-only table", "DELETE FROM poc.defaults WHERE id=1","defaults","id:int:NO,note:varchar:YES","","utf8mb4_general_ci"),
        .init("drop-charset-only", "DROP removes the charset-only table", "DROP TABLE poc.defaults","defaults","","","")
    ]

    static let rejections: [(QualificationCase, String, String)] = [
        (QualificationCase("explicit_innodb", "Reject explicit InnoDB without engine rewriting or applying following DDL"),"CREATE TABLE poc.explicit_innodb(id INT PRIMARY KEY) ENGINE=InnoDB","no engine rewriting"),
        (QualificationCase("collation_0900", "Reject unsupported 0900 collation without substitution or applying following DDL"),"CREATE TABLE poc.collation_0900(id INT PRIMARY KEY,v VARCHAR(12) COLLATE utf8mb4_0900_ai_ci)","no substitution"),
        (QualificationCase("charset_default", "Reject an incompatible charset default without applying following DDL"),"CREATE TABLE poc.charset_default(id INT PRIMARY KEY,v VARCHAR(12) CHARACTER SET utf8mb4)","no collation substitution"),
        (QualificationCase("charset_latin1", "Reject unsupported latin1 row encoding before applying DDL"),"CREATE TABLE poc.charset_latin1(id INT PRIMARY KEY,v VARCHAR(12) CHARACTER SET latin1)","unsupported discovered character set")
    ]
    static let native: [(QualificationCase, String)] = [
        (QualificationCase("omitted", "CREATE without ENGINE uses local engine and database charset defaults"),"CREATE TABLE poc.omitted(id INT PRIMARY KEY,v VARCHAR(12))"),
        (QualificationCase("bare_default", "Reject bare ENGINE=DEFAULT with syntax error 1064"),"CREATE TABLE poc.bare_default(id INT PRIMARY KEY) ENGINE=DEFAULT"),
        (QualificationCase("quoted_default", "Quoted DEFAULT resolves the engine according to the qualified server defaults"),"CREATE TABLE poc.quoted_default(id INT PRIMARY KEY) ENGINE='DEFAULT'"),
        (QualificationCase("collate_only", "COLLATE-only column resolves its associated character set"),"CREATE TABLE poc.collate_only(id INT PRIMARY KEY,v VARCHAR(12) COLLATE utf8mb4_bin)"),
        (QualificationCase("owning_database", "Qualified CREATE inherits the owning database defaults rather than the USE database"),"USE poc; CREATE TABLE otherdb.owning_database(id INT PRIMARY KEY,v VARCHAR(12))"),
        (QualificationCase("explicit", "Explicit InnoDB succeeds when allowed or stops native replication when disabled"),"CREATE TABLE poc.explicit(id INT PRIMARY KEY) ENGINE=InnoDB")
    ]

    static let swiftProfiles = ["swift.position.metadata-minimal", "swift.gtid.metadata-full"]
    static let nativeProfiles = ["native.unrestricted", "native.restricted"]

    struct Entry {
        let suite: String
        let test: QualificationCase
        let profiles: [String]
        let parent: String?
        let isGroup: Bool
        var key: String { suite + "/" + test.id }
    }
    static var registry: [Entry] {
        let top = [positive, group, unsupported, denied] + rejections.map { $0.0 }
        return top.map { Entry(suite: "ddl-suite", test: $0, profiles: swiftProfiles, parent: nil, isGroup: $0.id == group.id) }
            + changes.map { Entry(suite: "ddl-suite", test: $0.test, profiles: swiftProfiles, parent: group.id, isGroup: false) }
            + native.map { Entry(suite: "native-ddl-suite", test: $0.0, profiles: nativeProfiles, parent: nil, isGroup: false) }
    }
}
