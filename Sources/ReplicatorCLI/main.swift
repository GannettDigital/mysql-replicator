import Foundation
import ReplicatorCodec

let args = Array(CommandLine.arguments.dropFirst())
switch args {
case ["--version"]:
    print("mysql-replicator 0.1.0-dev (codec ABI \(Codec.abiVersion), capabilities \(Codec.capabilities))")
case [], ["--help"]:
    print("""
    mysql-replicator — development bootstrap
    Usage: mysql-replicator --version | --help
    Capture, inspect, SQLite relay and apply are not implemented yet.
    See PLAN/IMPLEMENTATION_STATUS.md for current gates.
    """)
default:
    FileHandle.standardError.write(Data("Unsupported command; run --help. No replication was started.\n".utf8))
    exit(64)
}
