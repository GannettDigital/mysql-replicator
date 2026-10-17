import Foundation

extension DMLCompatibilityCases {
    static let binaryDefaults=Case(id:"binarydefaults",definition:"id INT PRIMARY KEY,b BINARY(5) DEFAULT X'ff0001',v VARBINARY(8) DEFAULT 0xFF0001,a BINARY(5) DEFAULT 'hi',e VARBINARY(5) DEFAULT X'',z BINARY(0) DEFAULT X'',c CHAR(4) CHARACTER SET binary DEFAULT X'ff00',n BINARY(8) DEFAULT 1e2,q VARBINARY(8) DEFAULT '1e2'",phases:[
        .init(sql:"INSERT INTO poc.matrix_binarydefaults(id) VALUES(1),(2)",check:"SELECT COUNT(*)=2 AND SUM(HEX(b)='FF00010000' AND HEX(v)='FF0001' AND HEX(a)='6869000000' AND HEX(e)='' AND HEX(z)='' AND HEX(c)='FF000000' AND HEX(n)='3130300000000000' AND HEX(q)='316532')=2 FROM poc.matrix_binarydefaults"),
        .init(sql:"ALTER TABLE poc.matrix_binarydefaults ALTER b SET DEFAULT X'00ff02',ALTER v SET DEFAULT B'11111111',ADD extra VARBINARY(8) DEFAULT X'800003'; UPDATE poc.matrix_binarydefaults SET b=DEFAULT,v=DEFAULT WHERE id=1",check:"SELECT COUNT(*)=2 AND SUM(id=1 AND HEX(b)='00FF020000' AND HEX(v)='FF')=1 AND SUM(HEX(extra)='800003')=2 FROM poc.matrix_binarydefaults"),
        .init(sql:"ALTER TABLE poc.matrix_binarydefaults MODIFY a BINARY(6) DEFAULT X'ff0004',ALTER e DROP DEFAULT; INSERT INTO poc.matrix_binarydefaults(id,e) VALUES(3,NULL); UPDATE poc.matrix_binarydefaults SET v=X'0000ff00' WHERE id=1; DELETE FROM poc.matrix_binarydefaults WHERE id=2",check:"SELECT COUNT(*)=2 AND SUM(id=3 AND HEX(a)='FF0004000000' AND e IS NULL)=1 AND SUM(id=1 AND HEX(v)='0000FF00')=1 FROM poc.matrix_binarydefaults")
    ])
}
