import Foundation

extension DMLCompatibilityCases {
    static let identifierCase=Case(id:"identifiercase",definition:"id INT,Value INT DEFAULT 7,PRIMARY KEY(ID),KEY ValueKey(VALUE)",phases:[
        .init(sql:"INSERT INTO poc.matrix_identifiercase(ID) VALUES(1),(2)",check:"SELECT COUNT(*)=2 AND SUM(VALUE)=14 FROM poc.matrix_identifiercase"),
        .init(sql:"ALTER TABLE poc.matrix_identifiercase ALTER COLUMN VALUE SET DEFAULT 9, ADD extra INT DEFAULT 3 AFTER VALUE; UPDATE poc.matrix_identifiercase SET VALUE=DEFAULT,EXTRA=4 WHERE ID=1",check:"SELECT COUNT(*)=1 FROM poc.matrix_identifiercase WHERE id=1 AND Value=9 AND extra=4"),
        .init(sql:"ALTER TABLE poc.matrix_identifiercase CHANGE VALUE renamed BIGINT DEFAULT 5; ALTER TABLE poc.matrix_identifiercase RENAME INDEX valuekey TO RenamedKey; UPDATE poc.matrix_identifiercase SET RENAMED=DEFAULT WHERE ID=2",check:"SELECT COUNT(*)=1 FROM poc.matrix_identifiercase WHERE id=2 AND renamed=5"),
        .init(sql:"ALTER TABLE poc.matrix_identifiercase DROP INDEX renamedkey, DROP COLUMN EXTRA; DELETE FROM poc.matrix_identifiercase WHERE ID=1",check:"SELECT COUNT(*)=1 AND SUM(RENAMED)=5 FROM poc.matrix_identifiercase")])
}
