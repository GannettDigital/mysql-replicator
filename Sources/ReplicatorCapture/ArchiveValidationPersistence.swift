import Foundation
import ReplicatorCodec

/// Optional derived cache. The owner calls it only during serial validation,
/// never from the producer while application state is being updated.
public struct ArchiveValidationPersistence {
    public let prepare: ([String]) throws -> Void
    public let load: (String) throws -> Data?
    public let save: (String, Data) throws -> Void

    public init(
        prepare: @escaping ([String]) throws -> Void,
        load: @escaping (String) throws -> Data?, save: @escaping (String, Data) throws -> Void
    ) {
        self.prepare = prepare
        self.load = load
        self.save = save
    }
}

/// Increase version when event validation rules change. Only a fully scanned
/// file with no pending transaction can produce this record.
struct ArchiveFileValidation: Codable {
    let version: Int
    let identity: ArchiveFileIdentity
    let sourceUUID: String
    let sourceVersion: String
    let settings: [String: String]
    let maximumEventBytes: UInt32
    let previousGTIDs: String
    let preambleEndOffset: UInt64
    let firstGTID: String?
    let firstTransactionOffset: UInt64?
    let completedGTIDs: String
    struct Rotation: Codable {
        let file: String
        let position: UInt64
        init(_ coordinate: BinlogCoordinate) {
            file = coordinate.file
            position = coordinate.position
        }
        var coordinate: BinlogCoordinate { .init(file: file, position: position) }
    }
    let rotation: Rotation?

    func matches(_ manifest: ArchiveManifest, identity: ArchiveFileIdentity, maximumEventBytes: UInt32) -> Bool {
        version == 1 && self.identity == identity && sourceUUID == manifest.sourceUUID
            && sourceVersion == manifest.sourceVersion && settings == manifest.settings
            && self.maximumEventBytes == maximumEventBytes
    }
}
