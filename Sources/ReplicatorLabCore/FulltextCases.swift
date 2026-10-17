import Foundation

extension DDLCompatibilityCases {
    static let fulltextIndexes=Case("fulltext","FULLTEXT CREATE, ALTER, parser metadata, search results and restart",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,title VARCHAR(80),body TEXT,FULLTEXT KEY ft(title(2),body)) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",[
            .init("SELECT INDEX_NAME,INDEX_TYPE,IFNULL(COLLATION,'NULL'),IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND INDEX_TYPE='FULLTEXT' ORDER BY SEQ_IN_INDEX","ft\tFULLTEXT\tNULL\tNULL\nft\tFULLTEXT\tNULL\tNULL")]),
        .init("INSERT INTO ddlcompat.t VALUES(1,'quartz','cobalt mineral'),(2,'granite','silver mineral')",[
            .init("SELECT id FROM ddlcompat.t WHERE MATCH(title,body) AGAINST('+quartz' IN BOOLEAN MODE) ORDER BY id","1")]),
        .init("UPDATE ddlcompat.t SET title='granite',body='cobalt mineral' WHERE id=1",[
            .init("SELECT COUNT(*) FROM ddlcompat.t WHERE MATCH(title,body) AGAINST('+quartz' IN BOOLEAN MODE)","0")],restartBefore:true),
        .init("DROP INDEX ft ON ddlcompat.t"),
        .init("CREATE FULLTEXT INDEX ft ON ddlcompat.t(body)"),
        .init("ALTER TABLE ddlcompat.t RENAME INDEX ft TO ft_renamed"),
        .init("UPDATE ddlcompat.t SET body='quartz mineral' WHERE id=2",[
            .init("SELECT id FROM ddlcompat.t WHERE MATCH(body) AGAINST('+quartz' IN BOOLEAN MODE)","2")]),
        .init("DELETE FROM ddlcompat.t WHERE id=2",[
            .init("SELECT COUNT(*) FROM ddlcompat.t WHERE MATCH(body) AGAINST('+quartz' IN BOOLEAN MODE)","0")]),
        .init("ALTER TABLE ddlcompat.t DROP INDEX ft_renamed"),
        // Native InnoDB can retain deleted document IDs when its last FULLTEXT
        // index is replaced. Test ADD WITH PARSER on a separate table; see PLAN.
        .init("CREATE TABLE ddlcompat.ngram(id INT PRIMARY KEY,body TEXT) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
        .init("ALTER TABLE ddlcompat.ngram ADD FULLTEXT KEY ft(body) WITH PARSER ngram"),
        .init("INSERT INTO ddlcompat.ngram VALUES(3,'xyzzy mineral')",[
            .init("SELECT id FROM ddlcompat.ngram WHERE MATCH(body) AGAINST('xyzzy' IN BOOLEAN MODE) ORDER BY id","3")],restartBefore:true),
        .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.ngram"),
        .init("INSERT INTO ddlcompat.copy SELECT * FROM ddlcompat.ngram",[
            .init("SELECT id FROM ddlcompat.copy WHERE MATCH(body) AGAINST('xyzzy' IN BOOLEAN MODE) ORDER BY id","3")])])
}
