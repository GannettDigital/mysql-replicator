import Foundation

extension DDLCompatibilityCases {
    static let spatialPrefixIndexes = Case(
        "spatial-prefix-indexes",
        "5.7 geometry BTREE prefixes retain index metadata and spatial row bytes through DML and restart",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,g GEOMETRY,KEY by_geometry(g(32)))"),
            .init(
                "INSERT INTO ddlcompat.t VALUES(1,ST_GeomFromText('POINT(1 2)')),(2,ST_GeomFromText('LINESTRING(0 0,1 1)')),(3,NULL)",
                [
                    .init(
                        "SELECT INDEX_NAME,INDEX_TYPE,SUB_PART FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND INDEX_NAME='by_geometry'",
                        "by_geometry\tBTREE\t32")
                ]),
            .init(
                "UPDATE ddlcompat.t SET g=ST_GeomFromText('POINT(3 4)') WHERE id=1",
                [
                    .init("SELECT ST_AsText(g) FROM ddlcompat.t WHERE id=1", "POINT(3 4)")
                ], restartBefore: true),
            .init("ALTER TABLE ddlcompat.t DROP INDEX by_geometry, ADD KEY by_geometry(g(16),id)"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t"),
            .init("INSERT INTO ddlcompat.copy VALUES(4,ST_GeomFromText('POINT(4 5)'))", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init(
                "UPDATE ddlcompat.t SET g=ST_GeomFromText('POINT(0 0)') WHERE id=3",
                [
                    .init("SELECT id,ST_AsText(g) FROM ddlcompat.t ORDER BY id", "1\tPOINT(3 4)\n3\tPOINT(0 0)")
                ]),
        ],
        profileExclusions: [
            .forward: "MySQL 8.4 source rejects geometry BTREE prefixes (native error 1089).",
            .reverse: "MySQL 8.4 target rejects geometry BTREE prefixes (native error 1089).",
        ])
}
