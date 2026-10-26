import Foundation

/// Original fixtures, informed by both pinned MySQL trees. Each phase is checked
/// against source/native/target data before the next phase can overwrite evidence.
enum DMLCompatibilityCases {
    struct Phase {
        let sql: String
        let check: String
        var expectsJSONDiff = false
    }
    struct Case {
        let id: String
        let definition: String
        let phases: [Phase]
        var setup: String = ""
        var orderBy: String = "id"
        var rowMetadata: String? = nil
        var source84OnlyReason: String? = nil
        var profileExclusions: [LabProfile: String] = [:]
        // Keep the fixture for existing-schema tests after its replicated case moves.
        var replicatedReplacement: String? = nil
        func applies(to profile: LabProfile) -> Bool {
            profileExclusions[profile] == nil && (source84OnlyReason == nil || profile.sourceVersion == .mysql84)
        }
    }
    static var replicatedCases: [Case] { cases.filter { $0.replicatedReplacement == nil } }
    static let cases: [Case] =
        [
            // Distinct ngram tokens avoid engine-specific stopword matches.
            .init(
                id: "fulltext", definition: "id INT PRIMARY KEY,body TEXT,FULLTEXT KEY ft(body) WITH PARSER ngram",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_fulltext VALUES(1,'xyzzy'),(2,'qqvvq')",
                        check:
                            "SELECT COUNT(*)=1 AND MIN(id)=1 FROM poc.matrix_fulltext WHERE MATCH(body) AGAINST('xyzzy' IN BOOLEAN MODE)"
                    ),
                    .init(
                        sql: "UPDATE poc.matrix_fulltext SET body='rrwwr' WHERE id=1",
                        check:
                            "SELECT COUNT(*)=0 FROM poc.matrix_fulltext WHERE MATCH(body) AGAINST('xyzzy' IN BOOLEAN MODE)"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_fulltext WHERE id=2",
                        check:
                            "SELECT COUNT(*)=0 FROM poc.matrix_fulltext WHERE MATCH(body) AGAINST('qqvvq' IN BOOLEAN MODE)"
                    ),
                ], replicatedReplacement: "ddl-compat-fulltext"),
            characterCollations,
            nativeEncodings,
            exactChoices,
            choiceBoundaries,
            binaryChoices,
            legacyBinarySet,
            decimalDefaults,
            binaryDefaults,
            textDefaults,
            zeroWidth,
            identifierCase,
            unicodeIdentifiers,
            Case(
                id: "encodings",
                definition:
                    "id VARCHAR(12) CHARACTER SET latin1 COLLATE latin1_swedish_ci PRIMARY KEY,c CHAR(4) CHARACTER SET latin1 COLLATE latin1_bin,v VARCHAR(20) CHARACTER SET latin1 COLLATE latin1_bin,t TEXT CHARACTER SET latin1 COLLATE latin1_bin,a VARCHAR(20) CHARACTER SET ascii COLLATE ascii_general_ci,u VARCHAR(20) CHARACTER SET utf8 COLLATE utf8_bin DEFAULT '中',b CHAR(4) CHARACTER SET binary,doc JSON",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_encodings VALUES(CONVERT(0xE9 USING latin1),CONVERT(0xE92020 USING latin1),CONVERT(0x0080FF20 USING latin1),CONVERT(0xE980FF00 USING latin1),CONVERT(0x410020 USING ascii),DEFAULT,0xFF20,JSON_OBJECT('n',CAST('1.25' AS DECIMAL(3,2)))),('second',NULL,'',NULL,'','',NULL,NULL)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_encodings WHERE id=CONVERT(0xC9 USING latin1) AND HEX(c)='E9' AND HEX(v)='0080FF20' AND HEX(t)='E980FF00' AND HEX(a)='410020' AND HEX(u)='E4B8AD' AND HEX(b)='FF200000' AND JSON_TYPE(JSON_EXTRACT(doc,'$.n'))='DECIMAL'"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_encodings SET id=CONVERT(0xC958 USING latin1),v=CONVERT(0xFF00E9 USING latin1),a='Next',u=CONVERT(0xC3A9 USING utf8),doc=JSON_OBJECT('n',CAST('2.50' AS DECIMAL(3,2))) WHERE id=CONVERT(0xC9 USING latin1)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_encodings WHERE id=CONVERT(0xE978 USING latin1) AND HEX(id)='C958' AND HEX(v)='FF00E9' AND a='next' AND HEX(u)='C3A9' AND JSON_TYPE(JSON_EXTRACT(doc,'$.n'))='DECIMAL'"
                    ),
                    .init(
                        sql:
                            "ALTER TABLE poc.matrix_encodings ADD extra CHAR(3) CHARACTER SET ascii DEFAULT 'x'; UPDATE poc.matrix_encodings SET extra='Z  ',t=CONVERT(0xE900FF USING latin1) WHERE id=CONVERT(0xE958 USING latin1)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_encodings WHERE id=CONVERT(0xC958 USING latin1) AND HEX(extra)='5A' AND HEX(t)='E900FF'"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_encodings WHERE id=CONVERT(0xE978 USING latin1)",
                        check: "SELECT COUNT(*)=1 AND SUM(id='second')=1 AND SUM(c IS NULL)=1 FROM poc.matrix_encodings"
                    ),
                ]),
            Case(
                id: "widestrings",
                definition:
                    "id INT PRIMARY KEY,v VARCHAR(20000) CHARACTER SET latin1 COLLATE latin1_bin,b VARBINARY(20000)",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_widestrings VALUES(1,REPEAT(CONVERT(0xE9 USING latin1),18000),REPEAT(0xFF00,9000))",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_widestrings WHERE OCTET_LENGTH(v)=18000 AND OCTET_LENGTH(b)=18000 AND HEX(RIGHT(v,1))='E9' AND HEX(RIGHT(b,2))='FF00'"
                    ),
                    .init(
                        sql: "UPDATE poc.matrix_widestrings SET v=CONVERT(0x00FF USING latin1),b=0xFF WHERE id=1",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_widestrings WHERE HEX(v)='00FF' AND HEX(b)='FF'"),
                    .init(
                        sql: "DELETE FROM poc.matrix_widestrings WHERE id=1",
                        check: "SELECT COUNT(*)=0 FROM poc.matrix_widestrings"),
                ]),
            Case(
                id: "spatial",
                definition:
                    "id INT PRIMARY KEY,g GEOMETRY,p POINT NOT NULL,l LINESTRING,poly POLYGON,mp MULTIPOINT,ml MULTILINESTRING,mpl MULTIPOLYGON,gc GEOMETRYCOLLECTION,SPATIAL INDEX sp(p)",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_spatial VALUES(1,ST_GeomFromText('POINT(1 2)'),ST_GeomFromText('POINT(3 4)'),ST_GeomFromText('LINESTRING(0 0,1 1)'),ST_GeomFromText('POLYGON((0 0,0 2,2 2,2 0,0 0))'),ST_GeomFromText('MULTIPOINT(0 0,1 2)'),ST_GeomFromText('MULTILINESTRING((0 0,1 1),(2 2,3 3))'),ST_GeomFromText('MULTIPOLYGON(((0 0,0 2,2 2,2 0,0 0)))'),ST_GeomFromText('GEOMETRYCOLLECTION(POINT(1 2),LINESTRING(0 0,1 1))')),(2,NULL,ST_GeomFromText('POINT(3 4)',4326),NULL,NULL,NULL,NULL,NULL,GeometryCollection())",
                        check:
                            "SELECT COUNT(*)=2 AND SUM(g IS NULL)=1 AND SUM(ST_SRID(p)=4326)=1 AND SUM(ST_NumGeometries(gc)=0)=1 FROM poc.matrix_spatial"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_spatial SET id=10,g=ST_GeomFromText('GEOMETRYCOLLECTION(POINT(5 6))'),l=ST_GeomFromText('LINESTRING(-1 -2,3 4)'),gc=GeometryCollection() WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_spatial WHERE id=10 AND ST_NumGeometries(g)=1 AND ST_NumGeometries(gc)=0"
                    ),
                    .init(
                        sql:
                            "ALTER TABLE poc.matrix_spatial ADD extra GEOMETRYCOLLECTION; DROP INDEX sp ON poc.matrix_spatial; CREATE SPATIAL INDEX sp2 ON poc.matrix_spatial(p); UPDATE poc.matrix_spatial SET extra=ST_GeomFromText('GEOMETRYCOLLECTION(POINT(7 8))') WHERE id=10",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_spatial WHERE id=10 AND ST_NumGeometries(extra)=1"),
                    .init(
                        sql: "DELETE FROM poc.matrix_spatial WHERE id=10",
                        check: "SELECT COUNT(*)=1 AND SUM(id=2)=1 AND SUM(g IS NULL)=1 FROM poc.matrix_spatial"),
                ]),
            Case(
                id: "json", definition: "id INT PRIMARY KEY,doc JSON",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_json VALUES (1,JSON_OBJECT('n',CAST('18446744073709551615' AS UNSIGNED),'a',JSON_ARRAY(1,true,NULL))),(2,'null'),(3,NULL),(4,JSON_QUOTE(CONVERT(0xF09F988065CC81 USING utf8mb4))),(5,'1.0'),(6,JSON_OBJECT())",
                        check:
                            "SELECT COUNT(*)=6 AND SUM(doc IS NULL)=1 AND SUM(JSON_TYPE(doc)='NULL')=1 AND SUM(JSON_TYPE(doc)='DOUBLE')=1 FROM poc.matrix_json"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_json SET id=11,doc=JSON_SET(doc,'$.n',CAST('-9223372036854775808' AS SIGNED),'$.s',JSON_ARRAY('x','y')) WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_json WHERE id=11 AND JSON_UNQUOTE(JSON_EXTRACT(doc,'$.n'))='-9223372036854775808' AND JSON_LENGTH(JSON_EXTRACT(doc,'$.s'))=2"
                    ),
                    .init(
                        sql:
                            "ALTER TABLE poc.matrix_json ADD extra JSON; UPDATE poc.matrix_json SET doc=JSON_ARRAY(9007199254740993,1.25e0),extra='true' WHERE id=5",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_json WHERE id=5 AND JSON_UNQUOTE(JSON_EXTRACT(doc,'$[0]'))='9007199254740993' AND JSON_TYPE(JSON_EXTRACT(doc,'$[1]'))='DOUBLE' AND JSON_TYPE(extra)='BOOLEAN'"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_json WHERE id IN (2,4,5,6,11)",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_json WHERE id=3 AND doc IS NULL"),
                ]),
            Case(
                id: "typedjson",
                definition:
                    "id INT PRIMARY KEY,doc JSON,ts TIMESTAMP(6) NULL,b TINYBLOB,c BLOB,d MEDIUMBLOB,e LONGBLOB,f VARBINARY(4),g BINARY(4),bits BIT(9)",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_typedjson VALUES(1,NULL,'2024-02-29 12:34:56.123456',0x00FF,0x0027,0xFF00,0x0102,0x00FF,0x00FF,511),(2,NULL,'2024-02-29 12:34:56.123456',0x00FF,0x0027,0xFF00,0x0102,0x00FF,0x00FF,511)",
                        check: "SELECT COUNT(*)=2 AND SUM(doc IS NULL)=2 FROM poc.matrix_typedjson"),
                    .init(
                        sql:
                            "UPDATE poc.matrix_typedjson SET doc=JSON_OBJECT('decimal',CAST('-12345678901234567890123456789012345.123456789012345678901234567890' AS DECIMAL(65,30)),'date',CAST('2024-02-29' AS DATE),'time',CAST('-838:59:58.123456' AS TIME(6)),'datetime',CAST('2024-02-29 12:34:56.123456' AS DATETIME(6)),'timestamp',ts,'tiny',b,'blob',c,'medium',d,'long',e,'varbinary',f,'binary',g,'bits',bits)",
                        check:
                            "SELECT COUNT(*)=2 FROM poc.matrix_typedjson WHERE JSON_TYPE(JSON_EXTRACT(doc,'$.decimal'))='DECIMAL' AND JSON_UNQUOTE(JSON_EXTRACT(doc,'$.decimal'))='-12345678901234567890123456789012345.123456789012345678901234567890' AND JSON_TYPE(JSON_EXTRACT(doc,'$.date'))='DATE' AND JSON_TYPE(JSON_EXTRACT(doc,'$.time'))='TIME' AND JSON_TYPE(JSON_EXTRACT(doc,'$.datetime'))='DATETIME' AND JSON_TYPE(JSON_EXTRACT(doc,'$.timestamp'))='TIMESTAMP' AND JSON_TYPE(JSON_EXTRACT(doc,'$.bits'))='BIT' AND JSON_TYPE(JSON_EXTRACT(doc,'$.tiny'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.blob'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.medium'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.long'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.varbinary'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.binary'))='BLOB'"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_typedjson SET doc=JSON_ARRAY(CAST('0000-00-00' AS DATE),CAST('0000-00-00 00:00:00' AS DATETIME),CAST('18446744073709551615' AS UNSIGNED),CAST('1.00' AS DECIMAL(3,2))) WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_typedjson WHERE id=1 AND JSON_TYPE(JSON_EXTRACT(doc,'$[0]'))='DATE' AND JSON_TYPE(JSON_EXTRACT(doc,'$[1]'))='DATETIME' AND JSON_TYPE(JSON_EXTRACT(doc,'$[2]'))='UNSIGNED INTEGER' AND JSON_TYPE(JSON_EXTRACT(doc,'$[3]'))='DECIMAL'"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_typedjson", check: "SELECT COUNT(*)=0 FROM poc.matrix_typedjson"),
                ]),
            Case(
                id: "jsonpartial", definition: "id INT PRIMARY KEY,doc JSON",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_jsonpartial VALUES(1,JSON_OBJECT('padding',REPEAT('x',1000),'a',JSON_ARRAY(1,2,3),'d',CAST('1.00' AS DECIMAL(3,2))))",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_jsonpartial WHERE JSON_LENGTH(JSON_EXTRACT(doc,'$.a'))=3"
                    ),
                    .init(
                        sql:
                            "SET SESSION binlog_row_value_options='PARTIAL_JSON'; UPDATE poc.matrix_jsonpartial SET doc=JSON_SET(doc,'$.a[1]',CAST('123.45' AS DECIMAL(5,2)),'$.d',CAST('2024-02-29' AS DATE)) WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_jsonpartial WHERE JSON_TYPE(JSON_EXTRACT(doc,'$.a[1]'))='DECIMAL' AND JSON_UNQUOTE(JSON_EXTRACT(doc,'$.a[1]'))='123.45' AND JSON_TYPE(JSON_EXTRACT(doc,'$.d'))='DATE'",
                        expectsJSONDiff: true),
                    .init(
                        sql:
                            "SET SESSION binlog_row_value_options='PARTIAL_JSON'; UPDATE poc.matrix_jsonpartial SET doc=JSON_REMOVE(doc,'$.a[0]') WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_jsonpartial WHERE JSON_LENGTH(JSON_EXTRACT(doc,'$.a'))=2 AND JSON_TYPE(JSON_EXTRACT(doc,'$.a[0]'))='DECIMAL'",
                        expectsJSONDiff: true),
                    .init(
                        sql: "DELETE FROM poc.matrix_jsonpartial",
                        check: "SELECT COUNT(*)=0 FROM poc.matrix_jsonpartial"),
                ],
                source84OnlyReason:
                    "Partial JSON row events require an 8.0 or later source; 5.7 writes complete JSON documents."),
            Case(
                id: "floatbounds", definition: "id FLOAT(8,2) PRIMARY KEY,v FLOAT(8,2),u FLOAT(8,2) UNSIGNED",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_floatbounds VALUES(999999.99,999999.99,999999.99),(-999999.99,-999999.99,0)",
                        check:
                            "SELECT COUNT(*)=2 AND SUM(id)=0 AND SUM(v)=0 AND SUM(u)=1000000 FROM poc.matrix_floatbounds"
                    ),
                    .init(
                        sql: "UPDATE poc.matrix_floatbounds SET id=1,v=-999999.99,u=999999.99 WHERE id>0",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_floatbounds WHERE id=1 AND v+0e0=-1000000e0 AND u+0e0=1000000e0"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_floatbounds WHERE id<0",
                        check: "SELECT COUNT(*)=1 AND MIN(id)=1 FROM poc.matrix_floatbounds"),
                ]),
            Case(
                id: "zerofill",
                definition:
                    "id INT ZEROFILL PRIMARY KEY,a TINYINT(6) ZEROFILL DEFAULT 7,b DECIMAL(8,2) ZEROFILL DEFAULT 1.25,c FLOAT ZEROFILL DEFAULT 1.25,d DOUBLE(10,2) ZEROFILL DEFAULT 1.235,e INT(0) ZEROFILL,f BIGINT ZEROFILL,y YEAR ZEROFILL",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_zerofill(id) VALUES(0),(1),(2)",
                        check: "SELECT COUNT(*)=3 AND SUM(a)=21 AND SUM(b)=3.75 FROM poc.matrix_zerofill"),
                    .init(
                        sql:
                            "UPDATE poc.matrix_zerofill SET id=4294967295,a=255,b=999999.99,c=0.125,d=9.875,e=4294967295,f=18446744073709551615,y=2155 WHERE id=0",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_zerofill WHERE id=4294967295 AND a=255 AND b=999999.99 AND d=9.88 AND f=18446744073709551615 AND y=2155"
                    ),
                    .init(
                        sql:
                            "ALTER TABLE poc.matrix_zerofill MODIFY a TINYINT(8) ZEROFILL DEFAULT 9, ADD g MEDIUMINT ZEROFILL DEFAULT 42; UPDATE poc.matrix_zerofill SET a=DEFAULT,g=16777215 WHERE id=1",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_zerofill WHERE id=1 AND a=9 AND g=16777215"),
                    .init(
                        sql: "DELETE FROM poc.matrix_zerofill WHERE id IN (1,4294967295)",
                        check: "SELECT COUNT(*)=1 AND MIN(id)=2 FROM poc.matrix_zerofill"),
                ]),
            Case(
                id: "fixedfloating",
                definition:
                    "id DOUBLE(10,2) PRIMARY KEY,a FLOAT(10,2) DEFAULT 1.235,b DOUBLE(20,6) DEFAULT -1.23456789,c FLOAT(30,20) DEFAULT 0.1,d DOUBLE(200,0) DEFAULT 1e199,u FLOAT(10,2) UNSIGNED",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_fixedfloating(id,u) VALUES(1,0),(2,1.235),(3,NULL); INSERT INTO poc.matrix_fixedfloating VALUES(4,NULL,NULL,NULL,NULL,NULL)",
                        check:
                            "SELECT COUNT(*)=4 AND SUM(a IS NULL)=1 AND SUM(b=-1.234568)=3 FROM poc.matrix_fixedfloating"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_fixedfloating SET id=10.255,a=-99999.125,b=0.0000001,c=-0.00001,d=-1e199,u=9999.999 WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_fixedfloating WHERE id=10.26 AND a<0 AND b=0 AND c<0 AND d=-1e199 AND u=10000"
                    ),
                    .init(
                        sql:
                            "ALTER TABLE poc.matrix_fixedfloating ADD e DOUBLE(10,2) DEFAULT 9.875, MODIFY a FLOAT(12,3) DEFAULT -1.2345; UPDATE poc.matrix_fixedfloating SET a=DEFAULT,e=DEFAULT WHERE id=2",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_fixedfloating WHERE id=2 AND a< -1.23 AND a> -1.24 AND e=9.88"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_fixedfloating WHERE id IN (2,3,10.26)",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_fixedfloating WHERE id=4 AND a IS NULL AND b IS NULL"),
                ]),
            Case(
                id: "floating",
                definition: "id DOUBLE PRIMARY KEY,a FLOAT,b DOUBLE,c FLOAT UNSIGNED DEFAULT 1.23456789",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_floating VALUES(0,0,0,0),(1,0.1,0.1,0.125),(2,-0.1,-0.1,NULL),(3,1.1754943508222875e-38,2.2250738585072014e-308,1),(4,NULL,NULL,NULL)",
                        check: "SELECT COUNT(*)=5 AND SUM(a IS NULL)=1 AND SUM(c IS NULL)=2 FROM poc.matrix_floating"),
                    .init(
                        sql:
                            "UPDATE poc.matrix_floating SET id=10.25,a=1.401298464324817e-45,b=4.9406564584124654e-324,c=DEFAULT WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_floating WHERE id=10.25 AND a>0 AND a<1e-40 AND b>0 AND b<1e-310 AND c>1.23456 AND c<1.23458"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_floating SET a=3.4028234663852886e38,b=1.7976931348623157e308 WHERE id=2",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_floating WHERE id=2 AND a>3.40282e38 AND b>1.79769e308"),
                    .init(
                        sql:
                            "ALTER TABLE poc.matrix_floating ADD d DOUBLE PRECISION DEFAULT 1.25e-2, MODIFY c FLOAT(25) UNSIGNED DEFAULT 0.125; UPDATE poc.matrix_floating SET c=0.1,d=-1.25e12 WHERE id=3",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_floating WHERE id=3 AND c=0.1 AND d=-1.25e12"),
                    .init(
                        sql: "DELETE FROM poc.matrix_floating WHERE id IN (0,2,3,10.25)",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_floating WHERE id=4 AND a IS NULL AND b IS NULL"),
                ]),
            Case(
                id: "bits",
                definition: "id BIT(64) PRIMARY KEY,a BIT DEFAULT b'1',b BIT(7),c BIT(8),d BIT(9),e BIT(63)",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_bits VALUES(0,0,0,0,0,0),(18446744073709551615,1,127,255,511,9223372036854775807),(9223372036854775808,NULL,NULL,NULL,NULL,NULL)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_bits WHERE CAST(id AS UNSIGNED)=18446744073709551615 AND a+0=1 AND b+0=127 AND c+0=255 AND d+0=511 AND e+0=9223372036854775807"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_bits SET id=72623859790382856,a=DEFAULT,b=64,c=128,d=256,e=4611686018427387904 WHERE id=0",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_bits WHERE id=72623859790382856 AND a+0=1 AND b+0=64 AND c+0=128 AND d+0=256 AND e+0=4611686018427387904"
                    ),
                    .init(
                        sql:
                            "ALTER TABLE poc.matrix_bits MODIFY d BIT(16) DEFAULT b'100000000', ADD f BIT(8) DEFAULT b'11111111'; UPDATE poc.matrix_bits SET d=65535 WHERE id=18446744073709551615",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_bits WHERE id=18446744073709551615 AND d+0=65535 AND f+0=255"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_bits WHERE id IN (72623859790382856,18446744073709551615)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_bits WHERE id=9223372036854775808 AND a IS NULL AND e IS NULL"
                    ),
                ]),
            Case(
                id: "generated", definition: "id INT PRIMARY KEY,n INT,v INT AS (n+1) STORED",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_generated(id,n) VALUES(1,1),(2,NULL)",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_generated WHERE id=1 AND v=2"),
                    .init(
                        sql: "UPDATE poc.matrix_generated SET n=3 WHERE id=1",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_generated WHERE id=1 AND v=4"),
                    .init(
                        sql: "DELETE FROM poc.matrix_generated WHERE id=1",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_generated WHERE id=2 AND v IS NULL"),
                ], replicatedReplacement: "ddl-compat-generated"),
            Case(
                id: "fixed", definition: "id INT PRIMARY KEY,c CHAR(255),b BINARY(8)",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_fixed VALUES(1,CONVERT(0xF09F988065CC812020 USING utf8mb4),0x00FF),(2,'',X''),(3,NULL,NULL)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_fixed WHERE id=1 AND HEX(c)='F09F988065CC81' AND HEX(b)='00FF000000000000'"
                    ),
                    .init(
                        sql: "UPDATE poc.matrix_fixed SET c=REPEAT('x',255),b=0x0102030405060708 WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_fixed WHERE id=1 AND CHAR_LENGTH(c)=255 AND HEX(b)='0102030405060708'"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_fixed WHERE id IN (1,3)",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_fixed WHERE id=2 AND HEX(b)='0000000000000000'"),
                ]),
            // The exactchoices case separately checks lossy native metadata.
            Case(
                id: "enumzero", definition: "id ENUM('','one','two') PRIMARY KEY,e ENUM('','yes','no'),v INT UNSIGNED",
                phases: [
                    .init(
                        sql:
                            "SET SESSION sql_mode=''; INSERT INTO poc.matrix_enumzero VALUES(0,1,0),(1,0,1),(2,NULL,2)",
                        check:
                            "SELECT COUNT(*)=3 AND SUM(id+0=0)=1 AND SUM(id+0=1)=1 AND SUM(e+0=0)=1 AND SUM(e IS NULL)=1 FROM poc.matrix_enumzero"
                    ),
                    .init(
                        sql:
                            "SET SESSION sql_mode=''; UPDATE poc.matrix_enumzero SET e=0,v=10 WHERE id+0=0; UPDATE poc.matrix_enumzero SET e=1,v=11 WHERE id+0=1",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_enumzero WHERE id+0=0 AND e+0=0 AND v=10"),
                    .init(
                        sql: "DELETE FROM poc.matrix_enumzero WHERE id+0=0",
                        check: "SELECT COUNT(*)=2 AND SUM(id+0=0)=0 FROM poc.matrix_enumzero"),
                    .init(
                        sql: "SET SESSION sql_mode=''; UPDATE poc.matrix_enumzero SET id=0,e=0,v=20 WHERE id+0=2",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_enumzero WHERE id+0=0 AND e+0=0 AND v=20"),
                ], orderBy: "id+0", rowMetadata: "FULL"),
            Case(
                id: "choices", definition: "id INT PRIMARY KEY,e ENUM('','one','it''s','x,y','é'),s SET('a','b','c')",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_choices VALUES(1,1,0),(2,2,7),(3,'it''s','a,c'),(4,NULL,NULL),(5,'é','b')",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_choices WHERE id=1 AND e+0=1 AND s+0=0"),
                    .init(
                        sql: "UPDATE poc.matrix_choices SET e='x,y',s=6 WHERE id=3",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_choices WHERE id=3 AND e+0=4 AND s+0=6"),
                    .init(
                        sql: "DELETE FROM poc.matrix_choices WHERE id IN (1,2,3,5)",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_choices WHERE id=4 AND e IS NULL"),
                ], rowMetadata: "FULL"),
            Case(
                id: "widechoices",
                definition: "id INT PRIMARY KEY,e ENUM(" + (1...256).map { "'e\($0)'" }.joined(separator: ",")
                    + "),s SET(" + (1...64).map { "'s\($0)'" }.joined(separator: ",") + ")",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_widechoices VALUES(1,256,18446744073709551615)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_widechoices WHERE e+0=256 AND CAST(s AS UNSIGNED)=18446744073709551615"
                    ),
                    .init(
                        sql: "UPDATE poc.matrix_widechoices SET e=255,s=9223372036854775808 WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_widechoices WHERE e+0=255 AND CAST(s AS UNSIGNED)=9223372036854775808"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_widechoices WHERE id=1",
                        check: "SELECT COUNT(*)=0 FROM poc.matrix_widechoices"),
                ], rowMetadata: "FULL"),
            Case(
                id: "composite",
                definition: "id INT NOT NULL,report_date DATE NOT NULL,v VARCHAR(40),PRIMARY KEY(report_date,id)",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_composite VALUES(7,'2026-01-01','a'),(7,'2026-01-02','b'),(8,'2026-01-01','c')",
                        check: "SELECT COUNT(*)=3 AND SUM(id)=22 FROM poc.matrix_composite"),
                    .init(
                        sql:
                            "UPDATE poc.matrix_composite SET report_date='2026-01-03',v='moved-date' WHERE report_date='2026-01-01' AND id=7",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_composite WHERE id=7 AND report_date='2026-01-03' AND v='moved-date'"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_composite SET id=9,v='moved-id' WHERE report_date='2026-01-02' AND id=7",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_composite WHERE id=9 AND report_date='2026-01-02'"),
                    .init(
                        sql: "DELETE FROM poc.matrix_composite WHERE report_date='2026-01-01' AND id=8",
                        check: "SELECT COUNT(*)=2 AND SUM(id)=16 FROM poc.matrix_composite"),
                ], orderBy: "report_date,id"),
            Case(
                id: "textkey", definition: "id VARCHAR(20) COLLATE utf8mb4_unicode_ci PRIMARY KEY,v INT",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_textkey VALUES('Key',1),('other',2)",
                        check: "SELECT COUNT(*)=2 FROM poc.matrix_textkey"),
                    .init(
                        sql: "UPDATE poc.matrix_textkey SET id='KEY',v=3 WHERE id='Key'",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_textkey WHERE HEX(id)='4B4559' AND v=3"),
                    .init(
                        sql: "DELETE FROM poc.matrix_textkey WHERE id='key'",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_textkey WHERE id='other'"),
                ]),
            Case(
                id: "values", definition: "id INT PRIMARY KEY,v INT NOT NULL",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_values VALUES(1,10),(2,20),(3,30)",
                        check: "SELECT COUNT(*)=3 AND SUM(v)=60 FROM poc.matrix_values"),
                    .init(
                        sql: "UPDATE poc.matrix_values SET v=v*2 WHERE id IN (1,2)",
                        check: "SELECT SUM(v)=90 FROM poc.matrix_values"),
                    .init(
                        sql: "DELETE FROM poc.matrix_values WHERE id IN (1,3)",
                        check: "SELECT COUNT(*)=1 AND MIN(id)=2 AND MIN(v)=40 FROM poc.matrix_values"),
                ], replicatedReplacement: "ddl-compat-constraints"),
            Case(
                id: "upsert", definition: "id INT PRIMARY KEY,v INT NOT NULL,UNIQUE KEY uk(v)",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_upsert VALUES(1,10),(2,20)",
                        check: "SELECT COUNT(*)=2 FROM poc.matrix_upsert"),
                    .init(
                        sql: "INSERT INTO poc.matrix_upsert VALUES(1,11),(3,30) ON DUPLICATE KEY UPDATE v=VALUES(v)",
                        check: "SELECT COUNT(*)=3 AND SUM(v)=61 FROM poc.matrix_upsert"),
                    .init(
                        sql: "INSERT INTO poc.matrix_upsert VALUES(1,11) ON DUPLICATE KEY UPDATE v=VALUES(v)",
                        check: "SELECT COUNT(*)=3 AND SUM(v)=61 FROM poc.matrix_upsert"),
                ]),
            Case(
                id: "replace", definition: "id INT PRIMARY KEY,v INT NOT NULL,UNIQUE KEY uk(v)",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_replace VALUES(1,10),(2,20)",
                        check: "SELECT COUNT(*)=2 FROM poc.matrix_replace"),
                    .init(
                        sql: "REPLACE INTO poc.matrix_replace VALUES(1,20),(3,30)",
                        check: "SELECT COUNT(*)=2 AND SUM(id)=4 AND SUM(v)=50 FROM poc.matrix_replace"),
                ]),
            Case(
                id: "ignore", definition: "id INT PRIMARY KEY,v INT NOT NULL,UNIQUE KEY uk(v)",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_ignore VALUES(1,10)",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_ignore"),
                    .init(
                        sql: "INSERT IGNORE INTO poc.matrix_ignore VALUES(1,11),(2,20),(3,10)",
                        check: "SELECT COUNT(*)=2 AND SUM(v)=30 FROM poc.matrix_ignore"),
                    .init(
                        sql: "INSERT IGNORE INTO poc.matrix_ignore VALUES(1,99)",
                        check: "SELECT COUNT(*)=2 AND SUM(v)=30 FROM poc.matrix_ignore"),
                ]),
            Case(
                id: "select", definition: "id INT PRIMARY KEY,v INT NOT NULL",
                phases: [
                    .init(
                        sql: "INSERT INTO poc.matrix_select SELECT id+10,v*3 FROM poc.matrix_input",
                        check: "SELECT COUNT(*)=2 AND SUM(v)=90 FROM poc.matrix_select"),
                    .init(
                        sql: "UPDATE poc.matrix_select a JOIN poc.matrix_input b ON a.id=b.id+10 SET a.v=b.v+1",
                        check: "SELECT SUM(v)=32 FROM poc.matrix_select"),
                    .init(
                        sql: "DELETE a FROM poc.matrix_select a JOIN poc.matrix_input b ON a.id=b.id+10 WHERE b.id=1",
                        check: "SELECT COUNT(*)=1 AND MIN(id)=12 FROM poc.matrix_select"),
                ],
                setup:
                    "CREATE TABLE poc.matrix_input(id INT PRIMARY KEY,v INT NOT NULL); INSERT INTO poc.matrix_input VALUES(1,10),(2,20)"
            ),
            Case(
                id: "load", definition: "id INT PRIMARY KEY,v INT NOT NULL",
                phases: [
                    .init(
                        sql:
                            "SELECT 1,10 UNION ALL SELECT 2,20 INTO OUTFILE '/var/lib/mysql-files/replicator-dml.tsv'; LOAD DATA INFILE '/var/lib/mysql-files/replicator-dml.tsv' INTO TABLE poc.matrix_load",
                        check: "SELECT COUNT(*)=2 AND SUM(v)=30 FROM poc.matrix_load")
                ]),
            Case(
                id: "integers",
                definition:
                    "id TINYINT PRIMARY KEY,a TINYINT,b TINYINT UNSIGNED,c SMALLINT,d SMALLINT UNSIGNED,e MEDIUMINT,f MEDIUMINT UNSIGNED",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_integers VALUES(-128,-128,255,-32768,65535,-8388608,16777215),(127,127,0,32767,0,8388607,0)",
                        check: "SELECT COUNT(*)=2 AND MIN(e)=-8388608 AND MAX(f)=16777215 FROM poc.matrix_integers"),
                    .init(
                        sql: "UPDATE poc.matrix_integers SET id=0,a=NULL,b=1,c=-1,d=1,e=-1,f=1 WHERE id=-128",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_integers WHERE id=0 AND a IS NULL AND e=-1"),
                    .init(
                        sql: "DELETE FROM poc.matrix_integers WHERE id=127",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_integers"),
                ]),
            Case(
                id: "decimal",
                definition: "id INT PRIMARY KEY,a DECIMAL(65,30),b DECIMAL(10,2) UNSIGNED,c DECIMAL(4,4)",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_decimal VALUES(1,-12345678901234567890123456789012345.123456789012345678901234567890,99999999.99,-0.9999),(2,0,0,0)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_decimal WHERE a=-12345678901234567890123456789012345.123456789012345678901234567890 AND b=99999999.99 AND c=-0.9999"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_decimal SET a=99999999999999999999999999999999999.999999999999999999999999999999,b=NULL,c=0.0001 WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_decimal WHERE a=99999999999999999999999999999999999.999999999999999999999999999999 AND b IS NULL AND c=0.0001"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_decimal WHERE id=2",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_decimal"),
                ]),
            Case(
                id: "temporal",
                definition: "id INT PRIMARY KEY,d DATE,dt DATETIME(6),ts TIMESTAMP(6) NULL,t TIME(6),y YEAR",
                phases: [
                    .init(
                        sql:
                            "SET SESSION time_zone='+05:30'; INSERT INTO poc.matrix_temporal VALUES(1,'2024-02-29','9999-12-31 23:59:59.999999','2024-02-29 05:30:00.123456','-838:59:59.000000',2155),(2,'0000-00-00','0000-00-00 00:00:00','0000-00-00 00:00:00','-00:00:00.000001',0)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_temporal WHERE id=1 AND ts='2024-02-29 00:00:00.123456' AND t='-838:59:59.000000' AND y=2155"
                    ),
                    .init(
                        sql:
                            "UPDATE poc.matrix_temporal SET ts='2038-01-19 03:14:07.999999',t='838:59:59.000000',d=NULL,y=1901 WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_temporal WHERE id=1 AND ts='2038-01-19 03:14:07.999999' AND d IS NULL AND y=1901"
                    ),
                    .init(
                        sql: "DELETE FROM poc.matrix_temporal WHERE id=2",
                        check: "SELECT COUNT(*)=1 FROM poc.matrix_temporal"),
                ]),
            Case(
                id: "precision",
                definition:
                    "id INT PRIMARY KEY,t0 TIME,t1 TIME(1),t2 TIME(2),t3 TIME(3),t4 TIME(4),t5 TIME(5),t6 TIME(6),d0 DATETIME,d3 DATETIME(3),s0 TIMESTAMP NULL,s3 TIMESTAMP(3) NULL",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_precision VALUES(1,'-12:34:56','-00:00:00.1','-00:00:00.12','-00:00:00.123','-00:00:00.1234','-00:00:00.12345','-00:00:00.123456','2024-01-01 12:34:56','2024-01-01 12:34:56.789','1970-01-01 00:00:01','2024-01-01 12:34:56.789')",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_precision WHERE t6='-00:00:00.123456' AND d3='2024-01-01 12:34:56.789'"
                    ),
                    .init(
                        sql: "UPDATE poc.matrix_precision SET t1='12:34:56.1',t6='00:00:00',d3=NULL WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_precision WHERE t1='12:34:56.1' AND t6='00:00:00' AND d3 IS NULL"
                    ),
                ]),
            Case(
                id: "lob",
                definition:
                    "id INT PRIMARY KEY,a TINYTEXT,b TEXT,c MEDIUMTEXT,d LONGTEXT,e TINYBLOB,f BLOB,g MEDIUMBLOB,h LONGBLOB,KEY prefix_key(b(10))",
                phases: [
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_lob VALUES(1,CONVERT(0x0027F09F988065CC812020 USING utf8mb4),REPEAT('x',1000),REPEAT('y',70000),'',0x00FF275C,REPEAT(0xFF,1000),REPEAT(0x00FF,35000),NULL)",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_lob WHERE HEX(a)='0027F09F988065CC812020' AND OCTET_LENGTH(c)=70000 AND OCTET_LENGTH(g)=70000 AND h IS NULL"
                    ),
                    .init(
                        sql: "UPDATE poc.matrix_lob SET a=NULL,b='',c='short',e=X'',h=0x00FF WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_lob WHERE a IS NULL AND b='' AND c='short' AND e=X'' AND HEX(h)='00FF'"
                    ),
                    .init(sql: "DELETE FROM poc.matrix_lob WHERE id=1", check: "SELECT COUNT(*)=0 FROM poc.matrix_lob"),
                ]),
            Case(
                id: "defaults",
                definition:
                    "id INT PRIMARY KEY AUTO_INCREMENT,v INT NOT NULL DEFAULT 7,s VARCHAR(40) DEFAULT 'seed',ts TIMESTAMP(6) NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)",
                phases: [
                    .init(
                        sql:
                            "SET timestamp=1700000000.123456; INSERT INTO poc.matrix_defaults(s) VALUES(DEFAULT),('explicit')",
                        check: "SELECT COUNT(*)=2 AND SUM(id)=3 AND SUM(v)=14 FROM poc.matrix_defaults"),
                    .init(
                        sql: "SET timestamp=1700000001.654321; UPDATE poc.matrix_defaults SET v=9 WHERE id=1",
                        check:
                            "SELECT COUNT(*)=1 FROM poc.matrix_defaults WHERE id=1 AND v=9 AND ts='2023-11-14 22:13:21.654321'"
                    ),
                    .init(
                        sql:
                            "INSERT INTO poc.matrix_defaults(id,v,s,ts) VALUES(0,0,'zero',NULL),(20,20,'explicit',NULL)",
                        check: "SELECT COUNT(*)=4 AND MIN(id)=0 AND MAX(id)=20 FROM poc.matrix_defaults"),
                ]),
        ] + legacyFloatingAutoIncrement

    struct Rejection {
        let id: String
        let sourceDefinition: String
        let targetDefinition: String
        let values: String
        let reason: String
        var rowMetadata: String = "FULL"
        var sourceSession: String = ""
        // MyISAM retains the write when generated-value verification fails.
        var postWriteCheck: String? = nil
    }
    static let rejections: [Rejection] = [
        .init(
            id: "enum-minimal",
            sourceDefinition: "id INT PRIMARY KEY,v ENUM('a','b') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            targetDefinition: "id INT PRIMARY KEY,v ENUM('a','b') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            values: "(1,'a')", reason: "requires source binlog_row_metadata=FULL", rowMetadata: "MINIMAL"),
        .init(
            id: "enum-order",
            sourceDefinition: "id INT PRIMARY KEY,v ENUM('a','b') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            targetDefinition: "id INT PRIMARY KEY,v ENUM('b','a') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            values: "(1,'a')", reason: "labels or order differ"),
        .init(
            id: "set-order",
            sourceDefinition: "id INT PRIMARY KEY,v SET('a','b') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            targetDefinition: "id INT PRIMARY KEY,v SET('b','a') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            values: "(1,'a')", reason: "labels or order differ"),
        .init(
            id: "mysql84-collation",
            sourceDefinition: "id INT PRIMARY KEY,v VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci",
            targetDefinition: "id INT PRIMARY KEY,v VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci",
            values: "(1,'test')", reason: "collation"),
        .init(
            id: "decimal-scale", sourceDefinition: "id INT PRIMARY KEY,v DECIMAL(10,3)",
            targetDefinition: "id INT PRIMARY KEY,v DECIMAL(10,2)", values: "(1,1.234)", reason: "precision"),
        .init(
            id: "decimal-sign", sourceDefinition: "id INT PRIMARY KEY,v DECIMAL(10,2) UNSIGNED",
            targetDefinition: "id INT PRIMARY KEY,v DECIMAL(10,2)", values: "(1,1.23)", reason: "signedness"),
        .init(
            id: "time-precision", sourceDefinition: "id INT PRIMARY KEY,v TIME(6)",
            targetDefinition: "id INT PRIMARY KEY,v TIME(3)", values: "(1,'12:34:56.123456')", reason: "precision"),
        .init(
            id: "blob-width", sourceDefinition: "id INT PRIMARY KEY,v MEDIUMBLOB",
            targetDefinition: "id INT PRIMARY KEY,v BLOB", values: "(1,0x00FF)", reason: "type"),
        .init(
            id: "generated", sourceDefinition: "id INT PRIMARY KEY,v INT",
            targetDefinition: "id INT PRIMARY KEY,v INT AS (id+1) STORED", values: "(1,3)",
            reason: "target generated-column values differ", postWriteCheck: "COUNT(*)=1 AND MIN(id)=1 AND MIN(v)=2"),
    ]

    static func transactionCount(_ set: String) throws -> Int {
        var count = 0
        for server in set.split(separator: ",") {
            let parts = server.split(separator: ":")
            try require(parts.count >= 2, "invalid fixture GTID delta")
            for interval in parts.dropFirst() {
                if let first = interval.utf8.first,
                    (65...90).contains(first) || (97...122).contains(first) || first == 95
                {
                    try require(
                        interval.utf8.count <= 32
                            && interval.utf8.allSatisfy {
                                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
                            }, "invalid fixture GTID tag")
                    continue
                }
                let bounds = interval.split(separator: "-")
                guard let first = Int(bounds[0]), let last = Int(bounds.last!), first > 0, last >= first,
                    last - first < 10000
                else { throw LabError("invalid fixture GTID interval") }
                count += last - first + 1
            }
        }
        return count
    }
}
