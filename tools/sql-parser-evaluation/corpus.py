"""Evaluation SQL. Curated expectations concern syntax, not execution eligibility."""
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[2]
def cases():
    result=[]
    def add(name, sql, expected=True, modes="", **extra):
        for version in [50742,80408]:
            result.append(dict(id=f"{name}-{version}",group="curated",sql=sql,version=version,
                mode=modes,expected=expected.get(version) if isinstance(expected,dict) else expected,**extra))
    add("basic", "CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(20)) ENGINE=InnoDB")
    add("engine-default", "CREATE TABLE t(id INT PRIMARY KEY) ENGINE=DEFAULT",False)
    add("hex-upper", "CREATE TABLE t(v VARBINARY(4) DEFAULT X'00ff')")
    add("hex-lower", "CREATE TABLE t(v VARBINARY(4) DEFAULT x'00ff')")
    add("hex-empty", "CREATE TABLE t(v VARBINARY(4) DEFAULT X'')")
    add("bit-upper", "CREATE TABLE t(v BIT(8) DEFAULT B'01010101')")
    add("bit-lower", "CREATE TABLE t(v BIT(8) DEFAULT b'01010101')")
    add("empty-string", "CREATE TABLE t(v VARCHAR(4) DEFAULT '')")
    add("qualified-dot", "ALTER TABLE antlr_eval.t ADD c INT")
    add("charset-default", "ALTER TABLE t DEFAULT CHARSET=DEFAULT",{50742:True,80408:False})
    add("collate-default", "ALTER TABLE t COLLATE DEFAULT",{50742:True,80408:False})
    add("convert-default", "ALTER TABLE t CONVERT TO CHARACTER SET DEFAULT")
    add("compound-alter", "ALTER TABLE t ADD c VARCHAR(30), CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, DEFAULT COLLATE utf8mb4_general_ci")
    add("enum", "CREATE TABLE t(id INT PRIMARY KEY,e ENUM('café','a,b','a''b'),s SET('a','b'))")
    add("generated", "CREATE TABLE t(n INT,v VARCHAR(30),d DATE,c INT AS (CASE WHEN n BETWEEN 1 AND 10 THEN n ELSE 0 END) STORED,head VARCHAR(3) AS (SUBSTRING(v FROM 1 FOR 3)) STORED,clean VARCHAR(30) AS (TRIM(BOTH 'x' FROM v)) STORED,tomorrow DATE AS (DATE_ADD(d,INTERVAL 1 DAY)) STORED)")
    add("predicates", "CREATE TABLE t(n INT,c INT AS (NOT(n IN (1,3)) OR n IS NULL OR (n & 7) << 1) STORED)")
    add("json", "CREATE TABLE t(j JSON,g VARCHAR(40) AS (JSON_UNQUOTE(JSON_EXTRACT(j,'$.key'))) STORED)")
    add("json-default", "CREATE TABLE t(j JSON DEFAULT (JSON_OBJECT('a',1)))",{50742:False,80408:True})
    add("functional-index", "CREATE INDEX ix ON t ((CAST(v AS CHAR(20))))",{50742:False,80408:True})
    add("invisible-index", "CREATE INDEX ix ON t(v) INVISIBLE",{50742:False,80408:True})
    add("spatial", "CREATE TABLE t(id INT PRIMARY KEY,g GEOMETRY NOT NULL,SPATIAL INDEX(g)) ENGINE=InnoDB")
    add("srid", "CREATE TABLE t(g POINT NOT NULL SRID 4326)",{50742:False,80408:True})
    add("fulltext", "CREATE TABLE t(id INT PRIMARY KEY,v TEXT,FULLTEXT KEY ft(v) WITH PARSER ngram) ENGINE=InnoDB")
    add("foreign-key", "ALTER TABLE t ADD CONSTRAINT fk FOREIGN KEY(id) REFERENCES parent(id) ON UPDATE CASCADE")
    add("check", "CREATE TABLE t(id INT,CHECK(id>0))")
    add("check-enforced", "CREATE TABLE t(id INT,CONSTRAINT ck CHECK(id>0) NOT ENFORCED)",{50742:False,80408:True})
    add("partition", "CREATE TABLE t(id INT PRIMARY KEY) PARTITION BY RANGE(id) (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)")
    add("subpartition", "CREATE TABLE t(id INT,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(n) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)")
    add("key-algorithm", "CREATE TABLE t(id INT PRIMARY KEY) PARTITION BY KEY ALGORITHM=1 () PARTITIONS 2")
    add("partition-exchange", "ALTER TABLE t EXCHANGE PARTITION p0 WITH TABLE t2 WITHOUT VALIDATION")
    add("partition-reorg", "ALTER TABLE t REORGANIZE PARTITION p0 INTO (PARTITION p2 VALUES LESS THAN(5),PARTITION p3 VALUES LESS THAN(10))")
    add("procedure", "CREATE PROCEDURE p(IN n INT) BEGIN DECLARE x INT DEFAULT 0; WHILE x<n DO SET x=x+1; END WHILE; SELECT x; END")
    add("function", "CREATE FUNCTION f(n INT) RETURNS INT DETERMINISTIC RETURN n+1")
    add("trigger", "CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW SET NEW.id=ABS(NEW.id)")
    add("event", "CREATE EVENT ev ON SCHEDULE EVERY 1 DAY DO INSERT INTO t(id) VALUES(1)")
    add("view", "CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW vw AS SELECT id FROM t WITH CASCADED CHECK OPTION")
    add("rename", "RENAME TABLE t TO old_t,t2 TO t")
    add("temporary", "CREATE TEMPORARY TABLE tmp LIKE t")
    add("ctas", "CREATE TABLE copied AS SELECT * FROM t")
    add("unicode", "ALTER TABLE `café`.`表` ADD `élève` VARCHAR(20) DEFAULT 'été'")
    add("latin1", "CREATE TABLE t(v VARCHAR(20) DEFAULT 'café')",encoding="latin1")
    add("sjis", "CREATE TABLE t(v VARCHAR(20) DEFAULT '表')",encoding="shift_jis")
    add("introducer", "CREATE TABLE t(v VARCHAR(20) DEFAULT _latin1'café')")
    add("comment", "CREATE /* comment */ TABLE t(id INT) /*!80000 INVISIBLE */",{50742:True,80408:False})
    add("versioned-ddl", "/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER tr BEFORE INSERT ON t FOR EACH ROW SET NEW.id=1 */")
    add("mode-ansi-on", 'CREATE TABLE "t"("id" INT)',modes="ANSI_QUOTES")
    add("mode-ansi-off", 'CREATE TABLE "t"("id" INT)',False)
    add("mode-backslash-on", "CREATE TABLE t(v VARCHAR(20) DEFAULT 'a\\'b')")
    add("mode-backslash-off", "CREATE TABLE t(v VARCHAR(20) DEFAULT 'a\\'b')",False,modes="NO_BACKSLASH_ESCAPES")
    add("mode-pipes", "SELECT 'a'||'b'",modes="PIPES_AS_CONCAT")
    add("mode-or", "SELECT 'a'||'b'")
    add("mode-not-high", "SELECT NOT 1=2",modes="HIGH_NOT_PRECEDENCE")
    add("mode-not-low", "SELECT NOT 1=2")
    add("bad-column", "CREATE TABLE t(id)",False)
    add("bad-case", "CREATE TABLE t(n INT,c INT AS (CASE WHEN n THEN END))",False)
    add("bad-tail", "CREATE TABLE t(id INT) garbage",False)
    add("bad-quote", "CREATE TABLE `t(id INT)",False)
    add("two-statements", "CREATE TABLE t(id INT); DROP TABLE t",False)
    # Native references: mysql-test/t/partition_binlog.test (both source trees).
    for action in ["TRUNCATE", "DROP", "ANALYZE", "CHECK", "OPTIMIZE", "REPAIR"]:
        add("upstream-partition-"+action.lower(),f"ALTER TABLE t {action} PARTITION p0",
            reference="mysql-test/t/partition_binlog.test")

    # Extract complete ordinary Swift string literals. This is corpus extraction,
    # not SQL parsing. Exclude interpolated strings and do not claim native validity.
    seen=set()
    for directory in [ROOT/"Sources/ReplicatorLabCore",ROOT/"tests/ReplicatorApplyTests"]:
        for path in sorted(directory.glob("*.swift")):
            text=path.read_text()
            for match in re.finditer(r'"(?:[^"\\\n]|\\.)*"',text):
                literal=match.group()
                if "\\(" in literal: continue
                try: sql=json.loads(literal)
                except json.JSONDecodeError: continue
                if not re.match(r"^(CREATE|ALTER|DROP|RENAME|TRUNCATE)\s",sql,re.I): continue
                if sql in seen: continue
                seen.add(sql)
                for version in [50742,80408]:
                    result.append(dict(id=f"fixture-{len(seen)}-{version}",group="fixture",
                        sql=sql,version=version,mode="",expected=None,
                        reference=f"{path.relative_to(ROOT)}:{text[:match.start()].count(chr(10))+1}"))
    return result

if __name__=="__main__":
    output=ROOT/"artifacts/sql-parser-evaluation/corpus.json"
    output.write_text(json.dumps(cases(),indent=2,ensure_ascii=False)+"\n")
    print(output)
