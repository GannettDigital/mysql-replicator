import XCTest
@testable import ReplicatorApply

extension ForeignKeyTests {
    func testStoredGeneratedParentsAndChildrenUseNativeRules() throws {
        let parent=try schema("p(id INT PRIMARY KEY,b INT,v INT AS (b+1) STORED,UNIQUE KEY(v))")
        for suffix in [""," ON DELETE CASCADE"] {
            let child=try schema("c(id INT PRIMARY KEY,b INT,v INT AS (b+1) STORED,FOREIGN KEY(v) REFERENCES p(v)"+suffix+")")
            XCTAssertNoThrow(try ForeignKeyGraph.validate(child.foreignKeys,tables:[child.identity:child,parent.identity:parent],filter:TableFilter()))
            let plan=try DMLSQLPlan(child)
            XCTAssertEqual(plan.writeIndexes,[0,1]);XCTAssertEqual(plan.generatedIndexes,[2])
        }
        for suffix in [" ON UPDATE CASCADE"," ON DELETE SET NULL"," ON UPDATE SET NULL"] {
            let child=try schema("c(id INT PRIMARY KEY,v INT,FOREIGN KEY(v) REFERENCES p(v)"+suffix+")")
            XCTAssertNoThrow(try ForeignKeyGraph.validate(child.foreignKeys,tables:[child.identity:child,parent.identity:parent],filter:TableFilter()))
            let generated=try schema("c(id INT PRIMARY KEY,b INT,v INT AS (b+1) STORED,FOREIGN KEY(v) REFERENCES p(v)"+suffix+")")
            XCTAssertThrowsError(try ForeignKeyGraph.validate(generated.foreignKeys,tables:[generated.identity:generated,parent.identity:parent],filter:TableFilter())) { XCTAssertTrue(String(describing:$0).contains("stored generated FK")) }
        }
    }
    func testVirtualFKColumnsFailEvenWithMissingParentAllowed() throws {
        let parent=try schema("p(id INT PRIMARY KEY,b INT,v INT AS (b+1) VIRTUAL,UNIQUE KEY(v))")
        let child=try schema("c(id INT PRIMARY KEY,v INT,FOREIGN KEY(v) REFERENCES p(v))")
        XCTAssertThrowsError(try ForeignKeyGraph.validate(child.foreignKeys,tables:[child.identity:child,parent.identity:parent],filter:TableFilter())) { XCTAssertTrue(String(describing:$0).contains("virtual generated")) }
        let virtual=try schema("c(id INT PRIMARY KEY,b INT,v INT AS (b+1) VIRTUAL,FOREIGN KEY(v) REFERENCES p(v))")
        XCTAssertThrowsError(try ForeignKeyGraph.validate(virtual.foreignKeys,tables:[virtual.identity:virtual],filter:TableFilter(),missingParents:[parent.identity])) { XCTAssertTrue(String(describing:$0).contains("virtual generated")) }
    }
}
