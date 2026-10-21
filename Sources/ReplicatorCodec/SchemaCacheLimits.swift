/// Shared bound for target schema retention and capture schema interpretation.
/// DDL and reconnects still invalidate entries before they can be reused.
public enum SchemaCacheLimits {
    public static let maximumTables = 6_000
}
