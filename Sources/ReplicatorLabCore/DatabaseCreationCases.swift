import Foundation

/// Derived from pinned sql/sql_db.cc and mysql-test/t/ctype_create.test.
/// Setup and direct SQL are separate from replicated statements.
enum DatabaseCreationCases {
    struct Case {
        let test, native: QualificationCase
        let database, sql, prefix, collation: String
        let existing: Bool
        let prefix57: String
        init(_ id:String,_ description:String,_ database:String,_ sql:String,_ collation:String,
             prefix:String="",prefix57:String?=nil,existing:Bool=false,file:String=#filePath,line:UInt=#line) {
            test=QualificationCase("database-"+id,description,file:file,line:line)
            native=QualificationCase("native-database-"+id,description,file:file,line:line)
            self.database=database;self.sql=sql;self.collation=collation;self.prefix=prefix;self.existing=existing;self.prefix57=prefix57 ?? prefix
        }
        var metadataSQL:String {"SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='\(database)'"}
        var expected:String {"utf8mb4\t"+collation}
    }
    static let cases:[Case]=[
        .init("server-default","CREATE DATABASE inherits logged server defaults, not the USE database","created_default","CREATE DATABASE created_default","utf8mb4_bin",prefix:"SET SESSION collation_server=utf8mb4_bin; USE otherdb; "),
        .init("explicit","CREATE SCHEMA IF NOT EXISTS creates an absent database with explicit encoding","created_explicit","CREATE SCHEMA IF NOT EXISTS created_explicit DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci","utf8mb4_unicode_ci"),
        .init("charset-only","CREATE DATABASE with charset only uses the compatible logged charset default","created_charset","CREATE DATABASE created_charset CHARACTER SET utf8mb4","utf8mb4_general_ci",prefix:"SET SESSION default_collation_for_utf8mb4=utf8mb4_general_ci; ",prefix57:""),
        .init("collation-only","CREATE SCHEMA resolves a COLLATE-only definition's charset","created_collation","CREATE SCHEMA created_collation COLLATE utf8mb4_bin","utf8mb4_bin"),
        .init("existing-different","Conditional CREATE DATABASE keeps existing defaults and table data despite different options","created_explicit","CREATE DATABASE IF NOT EXISTS created_explicit CHARACTER SET latin1 COLLATE latin1_bin","utf8mb4_unicode_ci",existing:true),
        .init("existing-matching","Conditional CREATE SCHEMA keeps matching defaults and existing table data","created_explicit","CREATE SCHEMA IF NOT EXISTS created_explicit CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci","utf8mb4_unicode_ci",existing:true)
    ]
    static let nativeDuplicate=QualificationCase("native-database-duplicate","Duplicate CREATE DATABASE fails with 1007 and emits no source event")
    static let unsupported=QualificationCase("database-unsupported-collation","Stop before CREATE DATABASE when its explicit collation is unavailable on 5.7")
    static let unsupportedDefault=QualificationCase("database-unsupported-default","Stop before CREATE DATABASE when its inherited server collation is unavailable on 5.7")
    static let denied=QualificationCase("database-denied","Denied CREATE DATABASE keeps a pending intent and blocks following DDL")

    static func observeNative(_ h:NativeHarness,reporter:QualificationReporter) throws {
        var observations:[[String:Any]]=[]
        for test in cases {
            try reporter.run(test.native) {
                let before=try h.boundary("source")
                let warnings=try h.sql("source",test.prefix+test.sql+"; SHOW WARNINGS")
                // 5.7 has no default_collation_for_utf8mb4 variable; its utf8mb4
                // default is already general_ci. Other session setup is identical.
                let prefix=test.prefix57
                let direct=try h.sql("target57",prefix+test.sql+"; SHOW WARNINGS")
                for actual in [warnings,direct] {
                    try require(test.existing ? actual.hasPrefix("Note\t1007\t") : actual.isEmpty,"database warning mismatch: \(actual)")
                }
                let after=try h.boundary("source")
                try require(after.position>before.position && after.gtids != before.gtids,"successful database CREATE did not log an event")
                let wait=try h.sql("native","SELECT SOURCE_POS_WAIT('\(after.file)',\(after.position),20)")
                try require(wait != "NULL" && wait != "-1" && h.status()["Last_SQL_Errno"]=="0","native database creation did not converge")
                var row:[String:Any]=["id":test.native.id,"sql":test.sql,"warnings":warnings,"direct_warnings":direct,"before":before.json,"after":after.json]
                for service in h.services {
                    let actual=try h.sql(service,test.metadataSQL)
                    try require(actual==test.expected,"\(service) database defaults differ: \(actual)")
                    row[service]=actual
                }
                observations.append(row)
            }
        }
        try reporter.run(nativeDuplicate) {
            let before=try h.boundary("source")
            for service in ["source","target57"] {
                let result=try h.compose(["exec","-T","-e","MYSQL_PWD=fixture-root-only",service,"mysql","--no-defaults","-uroot","-e","CREATE DATABASE created_explicit"],checked:false)
                try require(result.status != 0 && String(decoding:result.stderr,as:UTF8.self).contains("ERROR 1007 "),"duplicate database was not rejected")
            }
            let after=try h.boundary("source")
            try require(before.file==after.file && before.position==after.position && before.gtids==after.gtids,"rejected database creation logged an event")
        }
        try writeJSON(observations,to:h.output.appendingPathComponent("database-creation-matrix.json"))
    }
}
