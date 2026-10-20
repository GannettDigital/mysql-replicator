import Foundation
import ReplicatorCapture
import ReplicatorConfiguration
import XCTest

@testable import ReplicatorApply

extension ConfigurationFileTests {
    func testMetadataCoversModelsAndExamplesDecode() throws {
        XCTAssertEqual(Set(ConfigurationOptions.metadata.keys), Set(ConfigurationOptions.descriptions.keys))
        let baseline = Data(try example().utf8)
        for (name, option) in ConfigurationOptions.metadata {
            XCTAssertFalse(option.commands.isEmpty, name)
            XCTAssertTrue(option.commands.isSubset(of: ConfigurationOptions.commands), name)
            if option.type == .section { continue }
            // Exercise the actual model decoder, not just the documentation type.
            let override = try ConfigurationOverrides(arguments: [
                "run", "--" + (name == "version" ? "config.version" : name), option.example,
            ])
            let data = try override.applying(to: baseline)
            _ = try ConfigurationFile.decode(ApplyConfiguration.self, from: data)
            if name.hasPrefix("archive.") {
                struct Archive: Decodable { let archive: ArchiveConfiguration }
                let base = try ConfigurationOverrides(arguments: ["replay", "--archive.directory", "./binlogs"])
                _ = try ConfigurationFile.decode(Archive.self, from: base.applying(to: data))
            }
            if !option.allowedValues.isEmpty && option.type != .stringList {
                XCTAssertTrue(option.allowedValues.contains(option.example), name)
            }
            if let value = option.defaultValue { try checkValue(value, type: option.type) }
            try checkValue(option.example, type: option.type)
            let cleared = try ConfigurationOverrides(arguments: [
                "run", "--" + (name == "version" ? "config.version" : name), "null",
            ])
            let withArchive = try ConfigurationOverrides(arguments: ["run", "--archive.directory", "./binlogs"])
            var nullData = try cleared.applying(to: withArchive.applying(to: baseline))
            if option.required {
                // Required means the field cannot be omitted. Yams can coerce
                // a null scalar to text for a nonoptional String, so omission
                // is the reliable decoder check for presence requirements.
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: nullData) as? [String: Any])
                func remove(_ path: ArraySlice<String>, from object: inout [String: Any]) {
                    let key = path.first!
                    if path.count == 1 {
                        object.removeValue(forKey: key)
                        return
                    }
                    var child = object[key] as! [String: Any]
                    remove(path.dropFirst(), from: &child)
                    object[key] = child
                }
                remove(name.split(separator: ".").map(String.init)[...], from: &object)
                nullData = try JSONSerialization.data(withJSONObject: object)
            }
            let decodeNull = {
                if name.hasPrefix("archive.") {
                    struct Archive: Decodable { let archive: ArchiveConfiguration }
                    _ = try ConfigurationFile.decode(Archive.self, from: nullData)
                } else {
                    _ = try ConfigurationFile.decode(ApplyConfiguration.self, from: nullData)
                }
            }
            if option.nullable {
                XCTAssertNoThrow(try decodeNull(), name)
            } else {
                XCTAssertThrowsError(try decodeNull(), name)
            }
        }
        XCTAssertEqual(
            Set(ConfigurationOptions.metadata["profile"]!.allowedValues),
            Set(ReplicationProfile.allCases.map(\.rawValue)))
        XCTAssertEqual(
            Set(ConfigurationOptions.metadata["skipErrors.codes"]!.allowedValues),
            Set(ApplyErrorCode.allCases.filter { $0 != .targetSQL }.map(\.rawValue)))
    }

    private func checkValue(_ yaml: String, type: ConfigurationOptionMetadata.ValueType) throws {
        let data = Data(yaml.utf8)
        switch type {
        case .boolean: _ = try ConfigurationFile.decode(Bool.self, from: data)
        case .integer: _ = try ConfigurationFile.decode(Int64.self, from: data)
        case .enumeration, .string: _ = try ConfigurationFile.decode(String.self, from: data)
        case .stringList: _ = try ConfigurationFile.decode([String].self, from: data)
        case .stringMap, .section: _ = try ConfigurationFile.decode([String: String].self, from: data)
        }
    }

    func testMetadataDefaultsMatchPolicyModels() throws {
        let documented = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(example().utf8))
        let policies: [String: Any] = [
            "batch": BatchPolicy(), "storage": StoragePolicy(), "statistics": StatisticsPolicy(),
            "sourceReconnect": SourceReconnectPolicy(), "targetReconnect": TargetReconnectPolicy(),
            "ddlPolicy": DDLPolicy(), "skipErrors": SkipErrorPolicy(), "compatibility": CompatibilityPolicy(),
        ]
        for (section, policy) in policies {
            // Active policy values in the full example are documented as defaults.
            if let sample = Mirror(reflecting: documented).children.first(where: { $0.label == section }),
                let value = Mirror(reflecting: sample.value).children.first?.value
            {
                let defaults = Mirror(reflecting: policy).children.map { String(describing: $0.value) }
                XCTAssertEqual(
                    Mirror(reflecting: value).children.map { String(describing: $0.value) }, defaults, section)
            }
            for child in Mirror(reflecting: policy).children {
                let name = section + "." + child.label!
                let option = try XCTUnwrap(ConfigurationOptions.metadata[name], name)
                let yaml = try XCTUnwrap(option.defaultValue, name)
                let data = Data(yaml.utf8)
                let expected: String
                switch option.type {
                case .string: expected = try ConfigurationFile.decode(String.self, from: data)
                case .stringList: expected = String(describing: try ConfigurationFile.decode([String].self, from: data))
                case .stringMap:
                    expected = String(describing: try ConfigurationFile.decode([String: String].self, from: data))
                default: expected = yaml
                }
                XCTAssertEqual(String(describing: child.value), expected, name)
            }
        }
        // These defaults are computed outside the Decodable policy structs.
        let yaml = """
            version: 2
            stateDirectory: ./state
            source:
              version: 2
              host: source
              port: 3306
              username: capture
              serverID: 9100
              sourceUUID: 00000000-0000-0000-0000-000000000001
              mode: gtid
              start: {executedGTIDs: ''}
            target: {username: applier, nativeAutoStartDisabled: true}
            """
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(yaml.utf8))
        let defaults: [String: String] = [
            "source.maximumEventBytes": String(config.source.eventByteLimit),
            "source.maximumTransactionBytes": String(config.source.transactionLimits.wireBytes),
            "source.lowerCaseTableNames": String(config.source.tableNameCaseSetting),
            "source.requireTLS": String(config.source.requireTLS),
            "target.requireTLS": String(config.target.requireTLS),
            "source.tlsVerification": config.source.tlsVerification.rawValue,
            "target.tlsVerification": config.target.tlsVerification.rawValue,
            "target.transport": config.target.transport.rawValue,
            "target.preserveSourceGTIDs": String(config.target.preserveSourceGTIDs),
            "target.explicitTableLocks": String(config.target.explicitTableLocks),
            "profile": config.replicationProfile.rawValue, "ddlTimeoutSeconds": String(config.ddlDeadline),
            "archive.maximumBytes": String(
                try ConfigurationFile.decode(ArchiveConfiguration.self, from: Data("directory: ./binlogs".utf8))
                    .byteLimit),
        ]
        for (name, value) in defaults { XCTAssertEqual(ConfigurationOptions.metadata[name]?.defaultValue, value, name) }
    }

    func testCommandSpecificReference() throws {
        let ctl = try ConfigurationOptions.help(command: "ctl")
        XCTAssertTrue(ctl.contains("--stateDirectory STRING"))
        XCTAssertFalse(ctl.contains("--target.host"))
        let replay = try ConfigurationOptions.help(command: "replay")
        XCTAssertTrue(replay.contains("--archive.directory STRING"))
        XCTAssertFalse(replay.contains("--sourceReconnect.enabled"))
        XCTAssertFalse(replay.contains("--statistics.sourcePollIntervalSeconds"))
        XCTAssertFalse(try ConfigurationOptions.help(command: "run").contains("--archive.directory"))
        XCTAssertFalse(try ConfigurationOptions.help(command: "fetch").contains("--archive.files"))
        XCTAssertFalse(try ConfigurationOptions.help(command: "fetch").contains("--target.host"))
        for command in ["inspect", "blackhole"] {
            let help = try ConfigurationOptions.help(command: command)
            XCTAssertTrue(help.contains("source-only file"))
            XCTAssertFalse(help.contains("--stateDirectory"))
        }
        let setting = try ConfigurationOptions.help(command: "replay", section: "source.stopAfterTransactions")
        XCTAssertTrue(setting.contains("INTEGER"))
        XCTAssertTrue(setting.contains("default: none"))
        XCTAssertTrue(setting.contains("null: allowed"))
        XCTAssertTrue(setting.contains("units: transactions"))
    }
}
