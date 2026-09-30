import Foundation

/// One declaration drives execution and offline catalog binding checks.
/// Source locations point to these scenario definitions.
enum DDLCoverageCases {
    struct DDLChange {
        let test: QualificationCase
        let sql, table, schema, rows, collation: String
        let database: String
        let warnings: [Int]
        let affectedRows: Int
        var isDML: Bool { ["INSERT","UPDATE","DELETE"].contains(String(sql.split(separator:" ")[0])) }
        var exactColumns: String {
            schema.split(separator:",").map { entry in
                let parts=entry.split(separator:":").map(String.init)
                let name=parts[0],base=parts[1],nullable=parts[2]
                let type=base == "varchar" ? "varchar(20)" : base == "varbinary" ? "varbinary(10)" : base == "bigint" ? "bigint unsigned" : base
                return [name,type,nullable,"<NULL>",name == "id" ? "PRI" : "","",base == "varchar" ? "utf8mb4" : "",base == "varchar" ? collation : ""].joined(separator:":")
            }.joined(separator:"\n")
        }
        init(_ id: String, _ name: String, _ sql: String, _ table: String, _ schema: String,
             _ rows: String, _ collation: String, database: String = "poc", warnings: [Int] = [], affectedRows: Int = 1, file: String = #filePath, line: UInt = #line) {
            test = QualificationCase(id, name, file: file, line: line)
            self.sql = sql; self.table = table; self.schema = schema
            self.rows = rows; self.collation = collation
            self.database=database; self.warnings=warnings; self.affectedRows=affectedRows
        }
    }

    static let positive = QualificationCase("positive", "Replicate INSERT, UPDATE and DELETE; compare rows, binlogs and SQLite checkpoints")
    static let group = QualificationCase("ddl", "Apply ordered DDL and DML; verify schema history, unchanged SQL and binlog order")
    static let missingTemplate = QualificationCase("ddl-like-missing-template", "Stop on a missing replica LIKE template before applying DDL or following events")
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
        .init("update-after-rename", "UPDATE moves the primary key and writes text through the renamed table", "UPDATE poc.renamed SET id=4,note='after' WHERE id=3","renamed","note:varchar:YES,id:int:NO","2\t6E657874\n4\t6166746572","utf8mb4_unicode_ci"),
        .init("delete-after-rename", "DELETE finds the changed primary key through the renamed table", "DELETE FROM poc.renamed WHERE id=4","renamed","note:varchar:YES,id:int:NO","2\t6E657874","utf8mb4_unicode_ci"),
        .init("drop-renamed-table", "DROP removes the renamed table", "DROP TABLE poc.renamed","renamed","","",""),
        .init("recreate-default-engine", "Recreate a dropped table with quoted DEFAULT engine and unsigned BIGINT key", "CREATE TABLE poc.renamed(id BIGINT UNSIGNED PRIMARY KEY,b VARBINARY(10) NULL) ENGINE='DEFAULT'","renamed","id:bigint:NO,b:varbinary:YES","",""),
        .init("truncate-empty-table", "TRUNCATE an already-empty table preserves schema and logs a source event", "TRUNCATE TABLE poc.renamed","renamed","id:bigint:NO,b:varbinary:YES","",""),
        .init("insert-after-empty-truncate", "INSERT preserves binary bytes after an empty-table TRUNCATE", "INSERT INTO poc.renamed VALUES(7,0x00FF)","renamed","id:bigint:NO,b:varbinary:YES","7\t00FF",""),
        .init("update-after-empty-truncate", "UPDATE changes the key and writes NULL after an empty-table TRUNCATE", "UPDATE poc.renamed SET id=8,b=NULL WHERE id=7","renamed","id:bigint:NO,b:varbinary:YES","8\tNULL",""),
        .init("delete-after-empty-truncate", "DELETE removes the changed key after an empty-table TRUNCATE", "DELETE FROM poc.renamed WHERE id=8","renamed","id:bigint:NO,b:varbinary:YES","",""),
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
        .init("drop-charset-only", "DROP removes the charset-only table", "DROP TABLE poc.defaults","defaults","","",""),
        .init("create-if-absent", "Conditional CREATE creates an absent table with explicit text collation", "CREATE TABLE IF NOT EXISTS poc.lifecycle (note VARCHAR(20) COLLATE utf8mb4_bin,id INT PRIMARY KEY) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci", "lifecycle", "note:varchar:YES,id:int:NO", "", "utf8mb4_bin"),
        .init("insert-after-create-if-absent", "Multirow INSERT distinguishes NULL, empty text and signed INT minimum", "INSERT INTO poc.lifecycle VALUES(NULL,-2147483648),('seed',1),('',2)", "lifecycle", "note:varchar:YES,id:int:NO", "-2147483648\tNULL\n1\t73656564\n2\t", "utf8mb4_bin", affectedRows: 3),
        .init("update-after-create-if-absent", "UPDATE moves signed INT minimum to maximum and writes exact UTF-8", "UPDATE poc.lifecycle SET id=2147483647,note=CONVERT(0xF09F988065CC81 USING utf8mb4) WHERE id=-2147483648", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564\n2\t\n2147483647\tF09F988065CC81", "utf8mb4_bin"),
        .init("delete-after-create-if-absent", "Multirow DELETE preserves the remaining seed row", "DELETE FROM poc.lifecycle WHERE id IN (2,2147483647)", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564", "utf8mb4_bin", affectedRows: 2),
        .init("create-if-matching", "Conditional CREATE with matching definition retains populated destination", "CREATE TABLE IF NOT EXISTS poc.lifecycle (note VARCHAR(20) COLLATE utf8mb4_bin,id INT PRIMARY KEY) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564", "utf8mb4_bin", warnings: [1050]),
        .init("insert-after-create-if-matching", "INSERT NULL follows conditional CREATE with matching definition", "INSERT INTO poc.lifecycle VALUES(NULL,2)", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564\n2\tNULL", "utf8mb4_bin"),
        .init("update-after-create-if-matching", "UPDATE changes primary key and preserves quote, backslash and NUL bytes", "UPDATE poc.lifecycle SET id=3,note=CONVERT(0x275C00 USING utf8mb4) WHERE id=2", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564\n3\t275C00", "utf8mb4_bin"),
        .init("delete-after-create-if-matching", "DELETE uses the original schema after conditional CREATE", "DELETE FROM poc.lifecycle WHERE id=3", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564", "utf8mb4_bin"),
        .init("create-if-different", "Conditional CREATE with different definition retains populated destination", "CREATE TABLE IF NOT EXISTS poc.lifecycle(id BIGINT UNSIGNED PRIMARY KEY,b VARBINARY(10))", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564", "utf8mb4_bin", warnings: [1050]),
        .init("insert-after-create-if-different", "INSERT NULL follows conditional CREATE with different definition", "INSERT INTO poc.lifecycle VALUES(NULL,2)", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564\n2\tNULL", "utf8mb4_bin"),
        .init("update-after-create-if-different", "UPDATE changes primary key and preserves quote, backslash and NUL bytes", "UPDATE poc.lifecycle SET id=3,note=CONVERT(0x275C00 USING utf8mb4) WHERE id=2", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564\n3\t275C00", "utf8mb4_bin"),
        .init("delete-after-create-if-different", "DELETE uses the original schema after conditional CREATE", "DELETE FROM poc.lifecycle WHERE id=3", "lifecycle", "note:varchar:YES,id:int:NO", "1\t73656564", "utf8mb4_bin"),
        .init("like-same", "CREATE LIKE same-schema copies local template metadata but no rows", "CREATE TABLE poc.cloned LIKE poc.lifecycle", "cloned", "note:varchar:YES,id:int:NO", "", "utf8mb4_bin"),
        .init("insert-after-like-same", "Multirow INSERT into LIKE clone distinguishes empty and NULL text", "INSERT INTO poc.cloned VALUES('clone',1),('',2),(NULL,3)", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65\n2\t\n3\tNULL", "utf8mb4_bin", affectedRows: 3),
        .init("update-after-like-same", "UPDATE moves the clone key and preserves UTF-8 and trailing spaces", "UPDATE poc.cloned SET id=4,note=CONVERT(0xC3A92020 USING utf8mb4) WHERE id=3", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65\n2\t\n4\tC3A92020", "utf8mb4_bin"),
        .init("delete-after-like-same", "Multirow DELETE leaves the clone-specific value intact", "DELETE FROM poc.cloned WHERE id IN (2,4)", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65", "utf8mb4_bin", affectedRows: 2),
        .init("like-cross", "CREATE LIKE cross-schema copies local template metadata but no rows", "CREATE TABLE otherdb.cloned LIKE poc.lifecycle", "cloned", "note:varchar:YES,id:int:NO", "", "utf8mb4_bin", database: "otherdb"),
        .init("insert-after-like-cross", "Multirow INSERT into LIKE clone distinguishes empty and NULL text", "INSERT INTO otherdb.cloned VALUES('clone',1),('',2),(NULL,3)", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65\n2\t\n3\tNULL", "utf8mb4_bin", database: "otherdb", affectedRows: 3),
        .init("update-after-like-cross", "UPDATE moves the clone key and preserves UTF-8 and trailing spaces", "UPDATE otherdb.cloned SET id=4,note=CONVERT(0xC3A92020 USING utf8mb4) WHERE id=3", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65\n2\t\n4\tC3A92020", "utf8mb4_bin", database: "otherdb"),
        .init("delete-after-like-cross", "Multirow DELETE leaves the clone-specific value intact", "DELETE FROM otherdb.cloned WHERE id IN (2,4)", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65", "utf8mb4_bin", database: "otherdb", affectedRows: 2),
        .init("like-conditional", "Conditional CREATE LIKE preserves destination values distinct from the template", "CREATE TABLE IF NOT EXISTS poc.cloned LIKE poc.lifecycle", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65", "utf8mb4_bin", warnings: [1050]),
        .init("insert-after-like-conditional", "INSERT follows conditional LIKE without replacing destination rows", "INSERT INTO poc.cloned VALUES(NULL,2)", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65\n2\tNULL", "utf8mb4_bin"),
        .init("update-after-like-conditional", "UPDATE changes the key and writes empty text after conditional LIKE", "UPDATE poc.cloned SET id=3,note='' WHERE id=2", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65\n3\t", "utf8mb4_bin"),
        .init("delete-after-like-conditional", "DELETE follows conditional LIKE using retained column order", "DELETE FROM poc.cloned WHERE id=3", "cloned", "note:varchar:YES,id:int:NO", "1\t636C6F6E65", "utf8mb4_bin"),
        .init("drop-if-present", "Conditional DROP present table logs and advances the replication stream", "DROP TABLE IF EXISTS poc.lifecycle", "lifecycle", "", "", ""),
        .init("recreate-after-drop-if-present", "Recreate dropped name with a different schema and unsigned BIGINT key", "CREATE TABLE poc.lifecycle(id BIGINT UNSIGNED PRIMARY KEY,b VARBINARY(10))", "lifecycle", "id:bigint:NO,b:varbinary:YES", "", ""),
        .init("insert-after-drop-if-present", "Multirow INSERT distinguishes empty binary and NULL at unsigned BIGINT limits", "INSERT INTO poc.lifecycle VALUES(0,X''),(18446744073709551615,NULL)", "lifecycle", "id:bigint:NO,b:varbinary:YES", "0\t\n18446744073709551615\tNULL", "", affectedRows: 2),
        .init("update-after-drop-if-present", "UPDATE moves unsigned maximum key and writes exact binary bytes", "UPDATE poc.lifecycle SET id=1,b=0x00FF275C WHERE id=18446744073709551615", "lifecycle", "id:bigint:NO,b:varbinary:YES", "0\t\n1\t00FF275C", ""),
        .init("delete-after-drop-if-present", "Multirow DELETE empties the recreated table", "DELETE FROM poc.lifecycle", "lifecycle", "id:bigint:NO,b:varbinary:YES", "", "", affectedRows: 2),
        .init("prepare-absent-drop", "DROP prepares an absent name for conditional DROP", "DROP TABLE poc.lifecycle", "lifecycle", "", "", ""),
        .init("drop-if-absent", "Conditional DROP absent table logs and advances the replication stream", "DROP TABLE IF EXISTS poc.lifecycle", "lifecycle", "", "", "", warnings: [1051]),
        .init("recreate-after-drop-if-absent", "Recreate dropped name with a different schema and unsigned BIGINT key", "CREATE TABLE poc.lifecycle(id BIGINT UNSIGNED PRIMARY KEY,b VARBINARY(10))", "lifecycle", "id:bigint:NO,b:varbinary:YES", "", ""),
        .init("insert-after-drop-if-absent", "Multirow INSERT distinguishes empty binary and NULL at unsigned BIGINT limits", "INSERT INTO poc.lifecycle VALUES(0,X''),(18446744073709551615,NULL)", "lifecycle", "id:bigint:NO,b:varbinary:YES", "0\t\n18446744073709551615\tNULL", "", affectedRows: 2),
        .init("update-after-drop-if-absent", "UPDATE moves unsigned maximum key and writes exact binary bytes", "UPDATE poc.lifecycle SET id=1,b=0x00FF275C WHERE id=18446744073709551615", "lifecycle", "id:bigint:NO,b:varbinary:YES", "0\t\n1\t00FF275C", ""),
        .init("delete-after-drop-if-absent", "Multirow DELETE empties the recreated table", "DELETE FROM poc.lifecycle", "lifecycle", "id:bigint:NO,b:varbinary:YES", "", "", affectedRows: 2),
        .init("cleanup-poc-lifecycle", "DROP cleans up poc.lifecycle", "DROP TABLE poc.lifecycle", "lifecycle", "", "", ""),
        .init("cleanup-poc-cloned", "DROP cleans up poc.cloned", "DROP TABLE poc.cloned", "cloned", "", "", ""),
        .init("cleanup-otherdb-cloned", "DROP cleans up otherdb.cloned", "DROP TABLE otherdb.cloned", "cloned", "", "", "", database: "otherdb")
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

    // Only these assertion-to-case contracts are currently instrumented. A group
    // pass supplies no implicit child assertions; remaining catalog checks stay gaps.
    static let evidenceContracts: [String: [String: [String]]] = [
        "ddl.table.rename.same-schema": ["schema-effects": ["rename-table"], "following-dml": ["insert-after-rename", "update-after-rename", "delete-after-rename"]],
        "ddl.table.truncate.populated": ["schema-effects": ["truncate-nonempty-table"], "following-dml": ["insert-after-truncate", "update-binary-null", "delete-unsigned-maximum"]],
        "ddl.table.truncate.empty": ["schema-effects": ["truncate-empty-table"], "following-dml": ["insert-after-empty-truncate", "update-after-empty-truncate", "delete-after-empty-truncate"]],
        "ddl.table.create-if-not-exists.absent": ["schema-effects": ["create-if-absent"], "following-dml": ["insert-after-create-if-absent", "update-after-create-if-absent", "delete-after-create-if-absent"]],
        "ddl.table.create-if-not-exists.matching": ["schema-effects": ["create-if-matching"], "following-dml": ["insert-after-create-if-matching", "update-after-create-if-matching", "delete-after-create-if-matching"]],
        "ddl.table.create-if-not-exists.different": ["schema-effects": ["create-if-different"], "following-dml": ["insert-after-create-if-different", "update-after-create-if-different", "delete-after-create-if-different"]],
        "ddl.table.create-like.same-schema": ["schema-effects": ["like-same"], "following-dml": ["insert-after-like-same", "update-after-like-same", "delete-after-like-same"]],
        "ddl.table.create-like.cross-schema": ["schema-effects": ["like-cross"], "following-dml": ["insert-after-like-cross", "update-after-like-cross", "delete-after-like-cross"]],
        "ddl.table.create-like.conditional-existing": ["schema-effects": ["like-conditional"], "following-dml": ["insert-after-like-conditional", "update-after-like-conditional", "delete-after-like-conditional"]],
        "ddl.table.drop-if-exists.present": ["schema-effects": ["drop-if-present"], "following-dml": ["recreate-after-drop-if-present", "insert-after-drop-if-present", "update-after-drop-if-present", "delete-after-drop-if-present"]],
        "ddl.table.drop-if-exists.absent": ["schema-effects": ["drop-if-absent"], "following-dml": ["recreate-after-drop-if-absent", "insert-after-drop-if-absent", "update-after-drop-if-absent", "delete-after-drop-if-absent"]]
    ]
    static func assertion(for caseID: String) -> String? {
        evidenceContracts.values.flatMap { $0 }.first { $0.value.contains(caseID) }?.key
    }

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
        let top = [positive, group, unsupported, denied, missingTemplate] + rejections.map { $0.0 }
        return top.map { Entry(suite: "ddl-suite", test: $0, profiles: swiftProfiles, parent: nil, isGroup: $0.id == group.id) }
            + changes.map { Entry(suite: "ddl-suite", test: $0.test, profiles: swiftProfiles, parent: group.id, isGroup: false) }
            + NativeLifecycleQualification.cases.map { Entry(suite: "native-ddl-suite", test: $0.test, profiles: nativeProfiles, parent: nil, isGroup: false) }
            + native.map { Entry(suite: "native-ddl-suite", test: $0.0, profiles: nativeProfiles, parent: nil, isGroup: false) }
    }
}
