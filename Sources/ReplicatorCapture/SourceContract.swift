/// Version-specific wire-session setup, separate from transport, download and
/// transaction assembly. The applier selects its qualified source contract.
public enum SourceContract: String {
    case mysql57 = "5.7."
    case mysql84 = "8.4."

    public var requiresHistoricalSchema: Bool { self == .mysql57 }

    var dumpSessionSQL: String {
        switch self {
        case .mysql57: return "SET @master_binlog_checksum='CRC32',@master_heartbeat_period=1000000000"
        case .mysql84: return "SET @source_binlog_checksum='CRC32',@source_heartbeat_period=1000000000"
        }
    }
}
