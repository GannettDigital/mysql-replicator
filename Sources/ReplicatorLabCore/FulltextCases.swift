import Foundation

extension DDLCompatibilityCases {
    static let fulltextIndexes = Case(
        "fulltext", "Full-Text Search: index changes and ngram parser",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,title VARCHAR(80),body TEXT,FULLTEXT KEY ft(title(2),body)) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.t VALUES(1,'quartz','cobalt mineral'),(2,'granite','silver mineral')",
                phaseEnd: "before-restart-1"),
            .init("UPDATE ddlcompat.t SET title='granite',body='cobalt mineral' WHERE id=1", restartBefore: true),
            .init("DROP INDEX ft ON ddlcompat.t"),
            .init("CREATE FULLTEXT INDEX ft ON ddlcompat.t(body)"),
            .init("ALTER TABLE ddlcompat.t RENAME INDEX ft TO ft_renamed"),
            .init("UPDATE ddlcompat.t SET body='quartz mineral' WHERE id=2"),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init("ALTER TABLE ddlcompat.t DROP INDEX ft_renamed"),
            // Keep ngram on a separate table. Native InnoDB can retain deleted
            // document IDs after replacement of its last FULLTEXT index.
            // See PLAN/FULLTEXT_SUPPORT.md.
            .init(
                "CREATE TABLE ddlcompat.ngram(id INT PRIMARY KEY,body TEXT) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init(
                "ALTER TABLE ddlcompat.ngram ADD FULLTEXT KEY ft(body) WITH PARSER ngram", phaseEnd: "before-restart-2"),
            .init("INSERT INTO ddlcompat.ngram VALUES(3,'xyzzy mineral')", restartBefore: true),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.ngram"),
            .init("INSERT INTO ddlcompat.copy SELECT * FROM ddlcompat.ngram"),
            .init(
                "CREATE TABLE ddlcompat.ngram_created(id INT PRIMARY KEY,body TEXT,FULLTEXT KEY ft(body) WITH PARSER ngram) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ngram_created VALUES(1,'xyzzy'),(2,'qqvvq')"),
            .init("UPDATE ddlcompat.ngram_created SET body='rrwwr' WHERE id=1"),
            .init("DELETE FROM ddlcompat.ngram_created WHERE id=2"),
            // Retain intermediate search results until the final query batch.
            .init(
                "CREATE TABLE ddlcompat.ft_inserted(id INT PRIMARY KEY,title VARCHAR(80),body TEXT,FULLTEXT KEY ft(title(2),body)) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.ft_inserted VALUES(1,'quartz','cobalt mineral'),(2,'granite','silver mineral')"),
            .init(
                "CREATE TABLE ddlcompat.ft_updated(id INT PRIMARY KEY,title VARCHAR(80),body TEXT,FULLTEXT KEY ft(title(2),body)) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.ft_updated VALUES(1,'quartz','cobalt mineral'),(2,'granite','silver mineral')"),
            .init("UPDATE ddlcompat.ft_updated SET title='granite',body='cobalt mineral' WHERE id=1"),
            .init(
                "CREATE TABLE ddlcompat.ft_renamed(id INT PRIMARY KEY,title VARCHAR(80),body TEXT,FULLTEXT KEY ft(title(2),body)) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.ft_renamed VALUES(1,'quartz','cobalt mineral'),(2,'granite','silver mineral')"),
            .init("UPDATE ddlcompat.ft_renamed SET title='granite',body='cobalt mineral' WHERE id=1"),
            .init("DROP INDEX ft ON ddlcompat.ft_renamed"),
            .init("CREATE FULLTEXT INDEX ft ON ddlcompat.ft_renamed(body)"),
            .init("ALTER TABLE ddlcompat.ft_renamed RENAME INDEX ft TO ft_renamed"),
            .init("UPDATE ddlcompat.ft_renamed SET body='quartz mineral' WHERE id=2"),
            .init(
                "CREATE TABLE ddlcompat.ft_deleted(id INT PRIMARY KEY,title VARCHAR(80),body TEXT,FULLTEXT KEY ft(title(2),body)) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.ft_deleted VALUES(1,'quartz','cobalt mineral'),(2,'granite','silver mineral')"),
            .init("UPDATE ddlcompat.ft_deleted SET title='granite',body='cobalt mineral' WHERE id=1"),
            .init("DROP INDEX ft ON ddlcompat.ft_deleted"),
            .init("CREATE FULLTEXT INDEX ft ON ddlcompat.ft_deleted(body)"),
            .init("ALTER TABLE ddlcompat.ft_deleted RENAME INDEX ft TO ft_renamed"),
            .init("UPDATE ddlcompat.ft_deleted SET body='quartz mineral' WHERE id=2"),
            .init("DELETE FROM ddlcompat.ft_deleted WHERE id=2"),
            // Preserve the separate CREATE/INSERT/UPDATE migration assertions.
            .init(
                "CREATE TABLE ddlcompat.ng_created(id INT PRIMARY KEY,body TEXT,FULLTEXT KEY ft(body) WITH PARSER ngram) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "CREATE TABLE ddlcompat.ng_inserted(id INT PRIMARY KEY,body TEXT,FULLTEXT KEY ft(body) WITH PARSER ngram) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ng_inserted VALUES(1,'xyzzy'),(2,'qqvvq')"),
            .init(
                "CREATE TABLE ddlcompat.ng_updated(id INT PRIMARY KEY,body TEXT,FULLTEXT KEY ft(body) WITH PARSER ngram) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ng_updated VALUES(1,'xyzzy'),(2,'qqvvq')"),
            .init("UPDATE ddlcompat.ng_updated SET body='rrwwr' WHERE id=1", phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "initial-fulltext-metadata",
                    check: .init(
                        "SELECT INDEX_NAME,INDEX_TYPE,IFNULL(COLLATION,'NULL'),IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ft_inserted' AND INDEX_TYPE='FULLTEXT' ORDER BY SEQ_IN_INDEX",
                        "ft\tFULLTEXT\tNULL\tNULL\nft\tFULLTEXT\tNULL\tNULL")),
                .init(
                    id: "inserted-search",
                    check: .init(
                        "SELECT id FROM ddlcompat.ft_inserted WHERE MATCH(title,body) AGAINST('+quartz' IN BOOLEAN MODE) ORDER BY id",
                        "1")),
                .init(
                    id: "updated-search",
                    check: .init(
                        "SELECT COUNT(*) FROM ddlcompat.ft_updated WHERE MATCH(title,body) AGAINST('+quartz' IN BOOLEAN MODE)",
                        "0")),
                .init(
                    id: "renamed-index-search",
                    check: .init(
                        "SELECT id FROM ddlcompat.ft_renamed WHERE MATCH(body) AGAINST('+quartz' IN BOOLEAN MODE)", "2")
                ),
                .init(
                    id: "deleted-search",
                    check: .init(
                        "SELECT COUNT(*) FROM ddlcompat.ft_deleted WHERE MATCH(body) AGAINST('+quartz' IN BOOLEAN MODE)",
                        "0")),
                .init(
                    id: "final-default-parser-rows",
                    check: .init("SELECT id,title,body FROM ddlcompat.t", "1\tgranite\tcobalt mineral")),
                .init(
                    id: "final-fulltext-index-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND INDEX_TYPE='FULLTEXT'",
                        "0")),
                .init(
                    id: "ft_renamed-metadata",
                    check: .init(
                        "SELECT INDEX_NAME,INDEX_TYPE,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ft_renamed' AND INDEX_TYPE='FULLTEXT' ORDER BY SEQ_IN_INDEX",
                        "ft_renamed\tFULLTEXT\tbody")),
                .init(
                    id: "ft_deleted-metadata",
                    check: .init(
                        "SELECT INDEX_NAME,INDEX_TYPE,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ft_deleted' AND INDEX_TYPE='FULLTEXT' ORDER BY SEQ_IN_INDEX",
                        "ft_renamed\tFULLTEXT\tbody")),
                .init(
                    id: "ngram-search",
                    check: .init(
                        "SELECT id FROM ddlcompat.ngram WHERE MATCH(body) AGAINST('xyzzy' IN BOOLEAN MODE) ORDER BY id",
                        "3")),
                .init(
                    id: "copy-search",
                    check: .init(
                        "SELECT id FROM ddlcompat.copy WHERE MATCH(body) AGAINST('xyzzy' IN BOOLEAN MODE) ORDER BY id",
                        "3")),
                .init(
                    id: "fulltext-ngram-create", check: .init("SHOW CREATE TABLE ddlcompat.ng_created", "ngram"),
                    fulltextParserIndex: "ft"),
                .init(
                    id: "alter-ngram-parser", check: .init("SHOW CREATE TABLE ddlcompat.ngram", "ngram"),
                    fulltextParserIndex: "ft"),
                .init(
                    id: "like-ngram-parser", check: .init("SHOW CREATE TABLE ddlcompat.copy", "ngram"),
                    fulltextParserIndex: "ft"),
                .init(
                    id: "fulltext-ngram-insert",
                    check: .init(
                        "SELECT COUNT(*)=1 AND MIN(id)=1 FROM ddlcompat.ng_inserted WHERE MATCH(body) AGAINST('xyzzy' IN BOOLEAN MODE)",
                        "1")),
                .init(
                    id: "fulltext-ngram-update",
                    check: .init(
                        "SELECT COUNT(*)=0 FROM ddlcompat.ng_updated WHERE MATCH(body) AGAINST('xyzzy' IN BOOLEAN MODE)",
                        "1")),
                .init(
                    id: "fulltext-ngram-delete",
                    check: .init(
                        "SELECT COUNT(*)=0 FROM ddlcompat.ngram_created WHERE MATCH(body) AGAINST('qqvvq' IN BOOLEAN MODE)",
                        "1")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.ft_inserted,ddlcompat.ft_updated,ddlcompat.ft_renamed,ddlcompat.ft_deleted,ddlcompat.ng_created,ddlcompat.ng_inserted,ddlcompat.ng_updated"
            ]))
}
