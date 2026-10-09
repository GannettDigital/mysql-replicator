import Foundation
import ReplicatorCapture
import ReplicatorCodec

public struct SkipSummary: Encodable {
    public let kind = "skip_summary"
    public let lifecycle = "STOPPED"
    public let skippedGTIDSet: String
    public let resumeGTIDSet: String
    public let resumePosition: BinlogCoordinate
    public let stateDirectory: String
}

public enum ApplySkip {
    /// Local state operation: no MySQL connection, SQL execution or automatic restart.
    /// The set must name exactly the captured pending group, with no write intents.
    public static func run(configuration: ApplyConfiguration, gtidSet: String) throws -> SkipSummary {
        try configuration.validate(offline:true)
        let set=try GTIDSet(gtidSet)
        let state=try StateStore(configuration:configuration,initialize:false,skipGTIDs:set)
        return try state.skip()
    }
}
