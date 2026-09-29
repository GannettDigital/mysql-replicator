import CReplicatorCodec

public enum Codec {
    public static var abiVersion: UInt32 { replicator_codec_abi_version() }
    public static var capabilities: UInt64 { replicator_codec_capabilities() }
}
