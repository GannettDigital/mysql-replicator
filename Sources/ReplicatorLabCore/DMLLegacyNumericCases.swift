import Foundation

extension DMLCompatibilityCases {
    static let legacyFloatingAutoIncrement: [Case] = [
        ("float","FLOAT"),("double","DOUBLE"),("fixedfloat","FLOAT(10,2)"),("unsigneddouble","DOUBLE UNSIGNED")
    ].map { suffix,type in
        let id="floatingauto"+suffix,table="poc.matrix_"+id
        return Case(id:id,definition:"id \(type) AUTO_INCREMENT PRIMARY KEY,v INT",phases:[
            .init(sql:"INSERT INTO \(table) VALUES(NULL,11),(NULL,22),(0,33)",check:"SELECT COUNT(*)=3 AND SUM(id=0)=1 AND SUM(id=1)=1 AND SUM(id=2)=1 FROM \(table)"),
            .init(sql:"UPDATE \(table) SET id=9.5,v=110 WHERE id=1; INSERT INTO \(table) VALUES(100,44),(NULL,55)",check:"SELECT COUNT(*)=5 AND SUM(id=9.5 AND v=110)=1 AND SUM(id=101 AND v=55)=1 FROM \(table)"),
            .init(sql:"ALTER TABLE \(table) ADD extra INT DEFAULT 7; UPDATE \(table) SET id=102,extra=8 WHERE id=101",check:"SELECT COUNT(*)=1 FROM \(table) WHERE id=102 AND extra=8"),
            .init(sql:"DELETE FROM \(table) WHERE id IN (0,2)",check:"SELECT COUNT(*)=3 AND SUM(id=9.5)=1 AND SUM(id=100)=1 AND SUM(id=102)=1 FROM \(table)")
        ],profileExclusions:[
            .forward:"MySQL 8.4 rejects FLOAT/DOUBLE AUTO_INCREMENT with native error 1063; the source cannot create this schema.",
            .reverse:"MySQL 8.4 rejects FLOAT/DOUBLE AUTO_INCREMENT with native error 1063; this is a target-version limit."
        ])
    }
}
