import Foundation

extension DMLCompatibilityCases {
    static let zeroWidth=Case(id:"zerowidth",definition:"id INT PRIMARY KEY,c CHAR(0) DEFAULT '',v VARCHAR(0) DEFAULT '',b BINARY(0) DEFAULT X'',w VARBINARY(0) DEFAULT X'',u VARCHAR(0) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X''",phases:[
        .init(sql:"INSERT INTO poc.matrix_zerowidth VALUES(1,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT),(2,NULL,NULL,NULL,NULL,NULL)",check:"SELECT COUNT(*)=2 AND SUM(id=1 AND HEX(c)='' AND HEX(v)='' AND HEX(b)='' AND HEX(w)='' AND HEX(u)='')=1 AND SUM(id=2 AND c IS NULL AND v IS NULL AND b IS NULL AND w IS NULL AND u IS NULL)=1 FROM poc.matrix_zerowidth"),
        .init(sql:"UPDATE poc.matrix_zerowidth SET c=NULL,v=NULL,b=NULL,w=NULL,u=NULL WHERE id=1; UPDATE poc.matrix_zerowidth SET c='',v='',b=X'',w=X'',u='' WHERE id=2",check:"SELECT COUNT(*)=2 AND SUM(id=1 AND c IS NULL AND v IS NULL AND b IS NULL AND w IS NULL AND u IS NULL)=1 AND SUM(id=2 AND HEX(c)='' AND HEX(v)='' AND HEX(b)='' AND HEX(w)='' AND HEX(u)='')=1 FROM poc.matrix_zerowidth"),
        .init(sql:"ALTER TABLE poc.matrix_zerowidth MODIFY v VARCHAR(4) DEFAULT 'x',MODIFY w VARBINARY(4) DEFAULT X'ff',MODIFY u VARCHAR(4) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X'4e2d'; UPDATE poc.matrix_zerowidth SET v='hi',w=X'ff00',u='中' WHERE id=1",check:"SELECT COUNT(*)=1 FROM poc.matrix_zerowidth WHERE id=1 AND v='hi' AND HEX(w)='FF00' AND HEX(u)='4E2D'"),
        .init(sql:"UPDATE poc.matrix_zerowidth SET v='',w=X'',u='' WHERE id=1; ALTER TABLE poc.matrix_zerowidth MODIFY v VARCHAR(0) DEFAULT '',MODIFY w VARBINARY(0) DEFAULT X'',MODIFY u VARCHAR(0) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X''; DELETE FROM poc.matrix_zerowidth WHERE id=2",check:"SELECT COUNT(*)=1 AND SUM(id=1 AND c IS NULL AND b IS NULL AND HEX(v)='' AND HEX(w)='' AND HEX(u)='')=1 FROM poc.matrix_zerowidth")
    ])
}
