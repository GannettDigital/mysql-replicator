import Foundation

extension DDLCompatibilityCases {
    static let spatialPrefixIndexes = Case(
        "spatial-prefix-indexes", "Geometry BTREE prefix indexes",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,g GEOMETRY,KEY by_geometry(g(32)))"),
            .init(
                "INSERT INTO ddlcompat.t VALUES(1,ST_GeomFromText('POINT(1 2)')),(2,ST_GeomFromText('LINESTRING(0 0,1 1)')),(3,NULL)",
                phaseEnd: "before-restart-1"),
            .init("UPDATE ddlcompat.t SET g=ST_GeomFromText('POINT(3 4)') WHERE id=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t DROP INDEX by_geometry, ADD KEY by_geometry(g(16),id)"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t", phaseEnd: "before-restart-2"),
            .init("INSERT INTO ddlcompat.copy VALUES(4,ST_GeomFromText('POINT(4 5)'))", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init("UPDATE ddlcompat.t SET g=ST_GeomFromText('POINT(0 0)') WHERE id=3"),
            .init("CREATE TABLE ddlcompat.gp_initial(id INT PRIMARY KEY,g GEOMETRY,KEY by_geometry(g(32)))"),
            .init(
                "INSERT INTO ddlcompat.gp_initial VALUES(1,ST_GeomFromText('POINT(1 2)')),(2,ST_GeomFromText('LINESTRING(0 0,1 1)')),(3,NULL)",
                phaseEnd: "write-and-retain-results"),
        ],
        profileExclusions: [
            .forward: "MySQL 8.4 source rejects geometry BTREE prefixes (native error 1089).",
            .reverse: "MySQL 8.4 target rejects geometry BTREE prefixes (native error 1089).",
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "initial-prefix",
                    check: .init(
                        "SELECT INDEX_NAME,INDEX_TYPE,SUB_PART FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gp_initial' AND INDEX_NAME='by_geometry' ORDER BY SEQ_IN_INDEX",
                        "by_geometry\tBTREE\t32")),
                .init(
                    id: "initial-point-line-and-null",
                    check: .init(
                        "SELECT id,ST_AsText(g) FROM ddlcompat.gp_initial ORDER BY id",
                        "1\tPOINT(1 2)\n2\tLINESTRING(0 0,1 1)\n3\tNULL")),
                .init(
                    id: "updated-and-deleted-geometry",
                    check: .init("SELECT id,ST_AsText(g) FROM ddlcompat.t ORDER BY id", "1\tPOINT(3 4)\n3\tPOINT(0 0)")),
                .init(
                    id: "like-copy-geometry",
                    check: .init("SELECT id,ST_AsText(g) FROM ddlcompat.copy", "4\tPOINT(4 5)")),
                .init(
                    id: "t-compound-prefix",
                    check: .init(
                        "SELECT COLUMN_NAME,INDEX_TYPE,IFNULL(SUB_PART,'NULL'),SEQ_IN_INDEX FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND INDEX_NAME='by_geometry' ORDER BY SEQ_IN_INDEX",
                        "g\tBTREE\t16\t1\nid\tBTREE\tNULL\t2")),
                .init(
                    id: "copy-compound-prefix",
                    check: .init(
                        "SELECT COLUMN_NAME,INDEX_TYPE,IFNULL(SUB_PART,'NULL'),SEQ_IN_INDEX FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='copy' AND INDEX_NAME='by_geometry' ORDER BY SEQ_IN_INDEX",
                        "g\tBTREE\t16\t1\nid\tBTREE\tNULL\t2")),
            ], databases: ["ddlcompat"], cleanup: ["DROP TABLE ddlcompat.gp_initial"]))
}
