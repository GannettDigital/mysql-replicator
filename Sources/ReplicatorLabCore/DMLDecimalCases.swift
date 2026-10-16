import Foundation

extension DMLCompatibilityCases {
    static let decimalDefaults=Case(id:"decimaldefaults",definition:"id INT PRIMARY KEY,a DECIMAL(8,2) DEFAULT 1.235,b DECIMAL(8,2) DEFAULT -1.235,c DECIMAL(8,2) DEFAULT 1.005e0,d DECIMAL(8,2) DEFAULT '1.005e0',z DECIMAL(8,2) ZEROFILL DEFAULT 9.999,u DECIMAL(8,2) UNSIGNED DEFAULT 0.005,n DECIMAL(8,0) DEFAULT -0.4",phases:[
        .init(sql:"INSERT INTO poc.matrix_decimaldefaults(id) VALUES(1),(2)",check:"SELECT COUNT(*)=2 AND SUM(a=1.24 AND b=-1.24 AND c=1.01 AND d=1.01 AND z=10 AND u=0.01 AND n=0)=2 FROM poc.matrix_decimaldefaults"),
        .init(sql:"ALTER TABLE poc.matrix_decimaldefaults ALTER a SET DEFAULT 2.345,ALTER b SET DEFAULT '-2.345',ALTER c SET DEFAULT 2.675e0,ADD extra DECIMAL(8,2) DEFAULT 9.995; UPDATE poc.matrix_decimaldefaults SET a=DEFAULT,b=DEFAULT,c=DEFAULT WHERE id=1",check:"SELECT COUNT(*)=2 AND SUM(id=1 AND a=2.35 AND b=-2.35 AND c=2.68)=1 AND SUM(extra=10)=2 FROM poc.matrix_decimaldefaults"),
        .init(sql:"ALTER TABLE poc.matrix_decimaldefaults MODIFY d DECIMAL(10,3) DEFAULT '1.2345',ALTER u DROP DEFAULT; INSERT INTO poc.matrix_decimaldefaults(id,u) VALUES(3,NULL); DELETE FROM poc.matrix_decimaldefaults WHERE id=2",check:"SELECT COUNT(*)=2 AND SUM(id=3 AND d=1.235 AND u IS NULL AND extra=10)=1 FROM poc.matrix_decimaldefaults")
    ])
}
