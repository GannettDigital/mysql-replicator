import Foundation

/// Server administration syntax is independent of the target storage engine.
enum LabMySQLVersion: String {
    case mysql57 = "5.7", mysql84 = "8.4"
    var replicaNoun: String { self == .mysql57 ? "SLAVE" : "REPLICA" }
    var startReplica: String { "START " + replicaNoun }
    var stopReplica: String { "STOP " + replicaNoun }
    var replicaStatus: String { "SHOW " + replicaNoun + " STATUS" }
    var positionWait: String { self == .mysql57 ? "MASTER_POS_WAIT" : "SOURCE_POS_WAIT" }
    var binlogStatus: String { self == .mysql57 ? "SHOW MASTER STATUS" : "SHOW BINARY LOG STATUS" }
    var resetBinlogs: String { self == .mysql57 ? "RESET MASTER" : "RESET BINARY LOGS AND GTIDS" }
    var changeSource: String { self == .mysql57 ? "CHANGE MASTER TO " : "CHANGE REPLICATION SOURCE TO " }
    var sourcePrefix: String { self == .mysql57 ? "MASTER_" : "SOURCE_" }
    var sqlRunningField: String { self == .mysql57 ? "Slave_SQL_Running" : "Replica_SQL_Running" }
    func position(_ boundary: Boundary) -> String {
        changeSource + sourcePrefix + "AUTO_POSITION=0," + sourcePrefix + "LOG_FILE='\(boundary.file)'," + sourcePrefix + "LOG_POS=\(boundary.position)"
    }
    func connect(host: String, caFile: String, boundary: Boundary, autoPosition: Bool) -> String {
        let p=sourcePrefix
        let position=autoPosition ? p+"AUTO_POSITION=1" : p+"AUTO_POSITION=0,"+p+"LOG_FILE='\(boundary.file)',"+p+"LOG_POS=\(boundary.position)"
        return changeSource+p+"HOST='\(host)',"+p+"USER='capture_fixture',"+p+"PASSWORD='fixture-capture-only',"+p+"SSL=1,"+p+"SSL_CA='\(caFile)',"+p+"SSL_VERIFY_SERVER_CERT=1,"+position
    }
}
