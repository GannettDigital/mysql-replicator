/// Admission limits, not allocations. A complete row event is never split.
public enum BinlogLimits {
    public static let maximumEventBytes: UInt32 = 1024 * 1024 * 1024
    public static let defaultEventBytes: UInt32 = 64 * 1024 * 1024
    public static let defaultTransactionBytes: UInt64 = 256 * 1024 * 1024
}
