import Foundation

/// Keep stored geometry bytes; native comparison also checks geographic point order.
enum DMLSpatialWorkflows {
    static let spatial = DMLExecutionWorkflow(
        title: "Spatial data types: stored geometry bytes, SRIDs and SPATIAL indexes",
        histories: [
            .init(table: "sv_after_insert", throughPhase: 1),
            .init(table: "sv_after_key_update", throughPhase: 2),
            .init(table: "sv_after_indexes", throughPhase: 3),
        ], phaseTransactions: [1, 1, 4, 1],
        predicateIDs: [
            "inserted-geometries-null-and-srid", "changed-key-line-and-collections",
            "added-collection-and-replaced-spatial-index", "deleted-changed-row",
        ],
        additionalChecks: [
            .init(
                id: "inserted-geometry-bytes",
                check: .init(
                    "SELECT id,IFNULL(HEX(g),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(poly),'NULL'),IFNULL(HEX(mp),'NULL'),IFNULL(HEX(ml),'NULL'),IFNULL(HEX(mpl),'NULL'),IFNULL(HEX(gc),'NULL') FROM poc.sv_after_insert ORDER BY id",
                    "1\t000000000101000000000000000000F03F0000000000000040\t0000000001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F\t00000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t000000000104000000020000000101000000000000000000000000000000000000000101000000000000000000F03F0000000000000040\t0000000001050000000200000001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F0102000000020000000000000000000040000000000000004000000000000008400000000000000840\t00000000010600000001000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t000000000107000000020000000101000000000000000000F03F000000000000004001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F\n2\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t00000000010700000000000000"
                )),
            .init(
                id: "point-srids-and-coordinates-1",
                check: .init(
                    "SELECT id,ST_SRID(p),ST_GeometryType(p),OCTET_LENGTH(p),LEAST(ST_X(p),ST_Y(p)),GREATEST(ST_X(p),ST_Y(p)) FROM poc.sv_after_insert ORDER BY id",
                    "1\t0\tPOINT\t25\t3\t4\n2\t4326\tPOINT\t25\t3\t4")),
            .init(
                id: "cartesian-point-bytes-1",
                check: .init(
                    "SELECT id,HEX(p) FROM poc.sv_after_insert WHERE ST_SRID(p)=0 ORDER BY id",
                    "1\t00000000010100000000000000000008400000000000001040")),
            .init(
                id: "spatial-index-1",
                check: .init(
                    "SELECT INDEX_NAME,INDEX_TYPE,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_insert' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                    "sp\tSPATIAL\t1\t1\tp\t32")),
            .init(
                id: "declared-geometry-types-1",
                check: .init(
                    "SELECT COLUMN_NAME,CASE WHEN DATA_TYPE='geomcollection' THEN 'geometrycollection' ELSE DATA_TYPE END,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_insert' ORDER BY ORDINAL_POSITION",
                    "id\tint\tNO\ng\tgeometry\tYES\np\tpoint\tNO\nl\tlinestring\tYES\npoly\tpolygon\tYES\nmp\tmultipoint\tYES\nml\tmultilinestring\tYES\nmpl\tmultipolygon\tYES\ngc\tgeometrycollection\tYES"
                )),
            .init(
                id: "key-update-geometry-bytes",
                check: .init(
                    "SELECT id,IFNULL(HEX(g),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(poly),'NULL'),IFNULL(HEX(mp),'NULL'),IFNULL(HEX(ml),'NULL'),IFNULL(HEX(mpl),'NULL'),IFNULL(HEX(gc),'NULL') FROM poc.sv_after_key_update ORDER BY id",
                    "2\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t00000000010700000000000000\n10\t00000000010700000001000000010100000000000000000014400000000000001840\t00000000010200000002000000000000000000F0BF00000000000000C000000000000008400000000000001040\t00000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t000000000104000000020000000101000000000000000000000000000000000000000101000000000000000000F03F0000000000000040\t0000000001050000000200000001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F0102000000020000000000000000000040000000000000004000000000000008400000000000000840\t00000000010600000001000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t00000000010700000000000000"
                )),
            .init(
                id: "point-srids-and-coordinates-2",
                check: .init(
                    "SELECT id,ST_SRID(p),ST_GeometryType(p),OCTET_LENGTH(p),LEAST(ST_X(p),ST_Y(p)),GREATEST(ST_X(p),ST_Y(p)) FROM poc.sv_after_key_update ORDER BY id",
                    "2\t4326\tPOINT\t25\t3\t4\n10\t0\tPOINT\t25\t3\t4")),
            .init(
                id: "cartesian-point-bytes-2",
                check: .init(
                    "SELECT id,HEX(p) FROM poc.sv_after_key_update WHERE ST_SRID(p)=0 ORDER BY id",
                    "10\t00000000010100000000000000000008400000000000001040")),
            .init(
                id: "spatial-index-2",
                check: .init(
                    "SELECT INDEX_NAME,INDEX_TYPE,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_key_update' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                    "sp\tSPATIAL\t1\t1\tp\t32")),
            .init(
                id: "added-column-geometry-bytes",
                check: .init(
                    "SELECT id,IFNULL(HEX(g),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(poly),'NULL'),IFNULL(HEX(mp),'NULL'),IFNULL(HEX(ml),'NULL'),IFNULL(HEX(mpl),'NULL'),IFNULL(HEX(gc),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.sv_after_indexes ORDER BY id",
                    "2\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t00000000010700000000000000\tNULL\n10\t00000000010700000001000000010100000000000000000014400000000000001840\t00000000010200000002000000000000000000F0BF00000000000000C000000000000008400000000000001040\t00000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t000000000104000000020000000101000000000000000000000000000000000000000101000000000000000000F03F0000000000000040\t0000000001050000000200000001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F0102000000020000000000000000000040000000000000004000000000000008400000000000000840\t00000000010600000001000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t00000000010700000000000000\t0000000001070000000100000001010000000000000000001C400000000000002040"
                )),
            .init(
                id: "point-srids-and-coordinates-3",
                check: .init(
                    "SELECT id,ST_SRID(p),ST_GeometryType(p),OCTET_LENGTH(p),LEAST(ST_X(p),ST_Y(p)),GREATEST(ST_X(p),ST_Y(p)) FROM poc.sv_after_indexes ORDER BY id",
                    "2\t4326\tPOINT\t25\t3\t4\n10\t0\tPOINT\t25\t3\t4")),
            .init(
                id: "cartesian-point-bytes-3",
                check: .init(
                    "SELECT id,HEX(p) FROM poc.sv_after_indexes WHERE ST_SRID(p)=0 ORDER BY id",
                    "10\t00000000010100000000000000000008400000000000001040")),
            .init(
                id: "spatial-index-3",
                check: .init(
                    "SELECT INDEX_NAME,INDEX_TYPE,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_indexes' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                    "sp2\tSPATIAL\t1\t1\tp\t32")),
            .init(
                id: "declared-geometry-types-3",
                check: .init(
                    "SELECT COLUMN_NAME,CASE WHEN DATA_TYPE='geomcollection' THEN 'geometrycollection' ELSE DATA_TYPE END,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_indexes' ORDER BY ORDINAL_POSITION",
                    "id\tint\tNO\ng\tgeometry\tYES\np\tpoint\tNO\nl\tlinestring\tYES\npoly\tpolygon\tYES\nmp\tmultipoint\tYES\nml\tmultilinestring\tYES\nmpl\tmultipolygon\tYES\ngc\tgeometrycollection\tYES\nextra\tgeometrycollection\tYES"
                )),
            .init(
                id: "remaining-null-and-empty-row",
                check: .init(
                    "SELECT id,IFNULL(HEX(g),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(poly),'NULL'),IFNULL(HEX(mp),'NULL'),IFNULL(HEX(ml),'NULL'),IFNULL(HEX(mpl),'NULL'),IFNULL(HEX(gc),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.matrix_spatial ORDER BY id",
                    "2\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t00000000010700000000000000\tNULL")),
            .init(
                id: "point-srids-and-coordinates-4",
                check: .init(
                    "SELECT id,ST_SRID(p),ST_GeometryType(p),OCTET_LENGTH(p),LEAST(ST_X(p),ST_Y(p)),GREATEST(ST_X(p),ST_Y(p)) FROM poc.matrix_spatial ORDER BY id",
                    "2\t4326\tPOINT\t25\t3\t4")),
            .init(
                id: "cartesian-point-bytes-4",
                check: .init("SELECT id,HEX(p) FROM poc.matrix_spatial WHERE ST_SRID(p)=0 ORDER BY id", "")),
            .init(
                id: "spatial-index-4",
                check: .init(
                    "SELECT INDEX_NAME,INDEX_TYPE,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_spatial' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                    "sp2\tSPATIAL\t1\t1\tp\t32")),
        ], expectedDDL: 10, expectedRows: 14)
}
