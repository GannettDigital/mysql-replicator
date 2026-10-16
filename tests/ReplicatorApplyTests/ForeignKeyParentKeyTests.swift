import XCTest
@testable import ReplicatorApply

extension ForeignKeyTests {
    func testNativeParentKeyRulesAndSessionSettings() {
        let old = NativeReplicationRules(sourceVersion:50700,targetVersion:50700)
        let newer = NativeReplicationRules(sourceVersion:50700,targetVersion:80400)
        XCTAssertEqual(old.foreignKeyParentKeys,.innodb)
        XCTAssertEqual(newer.foreignKeyParentKeys,.innodb)
        XCTAssertNil(old.foreignKeySessionSQL)
        XCTAssertEqual(newer.foreignKeySessionSQL,"SET SESSION restrict_fk_on_non_standard_key=OFF")
    }

    func testNativeNonuniqueAndCompositePrefixParentKeys() throws {
        let child = try schema("c(id INT PRIMARY KEY,pid INT,CONSTRAINT cf FOREIGN KEY(pid) REFERENCES p(a))")
        for definition in ["p(id INT PRIMARY KEY,a INT,KEY n(a))","p(a INT,b INT,PRIMARY KEY(a,b))","p(id INT PRIMARY KEY,a INT,b INT,UNIQUE KEY ab(a,b))"] {
            let parent = try schema(definition)
            XCTAssertTrue(parent.hasForeignKeyParentIndex(["a"],rule:.innodb))
            XCTAssertFalse(parent.hasForeignKeyParentIndex(["a"],rule:.completeUnique))
            XCTAssertNoThrow(try ForeignKeyGraph.validate(child.foreignKeys,tables:[child.identity:child,parent.identity:parent],filter:TableFilter(),parentKeys:.innodb))
        }
    }

    func testExtendedIndexesUsePossibleClusteredKeysNotLookupIdentity() throws {
        for definition in ["p(id INT PRIMARY KEY,a INT,KEY n(a))","p(id INT NOT NULL,a INT,UNIQUE KEY uk(id),KEY n(a))"] {
            var parent = try schema(definition)
            parent.savedRowIdentity = .init(kind:.fullRow,index:"",columns:["a"])
            XCTAssertTrue(parent.hasForeignKeyParentIndex(["a","id"],rule:.innodb))
            XCTAssertFalse(parent.hasForeignKeyParentIndex(["id","a"],rule:.innodb))
        }
    }

    func testNativeParentIndexStillRejectsMissingReorderedAndPrefixColumns() throws {
        let plain = try schema("p(id INT PRIMARY KEY,a INT,b INT,KEY ab(a,b))")
        XCTAssertFalse(plain.hasForeignKeyParentIndex(["b"],rule:.innodb))
        XCTAssertFalse(plain.hasForeignKeyParentIndex(["b","a"],rule:.innodb))
        XCTAssertFalse(plain.hasForeignKeyParentIndex(["a","missing"],rule:.innodb))
        let prefix = try schema("p(id INT PRIMARY KEY,a VARCHAR(30),KEY short(a(5)))")
        XCTAssertFalse(prefix.hasForeignKeyParentIndex(["a"],rule:.innodb))
        XCTAssertFalse(prefix.hasForeignKeyParentIndex(["a","id"],rule:.innodb))
        let noClustered = try schema("p(id INT,a INT,KEY n(a))")
        XCTAssertFalse(noClustered.hasForeignKeyParentIndex(["a","id"],rule:.innodb))
    }
}
