import NIOSSL

public enum TLSVerification: String, Decodable {
    case verifyIdentity = "verify-identity"
    case verifyCA = "verify-ca"
}

/// Both client endpoints use the same certificate policy and trust roots.
public enum ConnectionTLS {
    public static func validate(required:Bool,verification:TLSVerification,hostname:String?,caFile:String?,endpoint:String) throws {
        if required {
            if verification == .verifyIdentity {
                guard !(hostname ?? "").isEmpty else { throw CaptureError("\(endpoint) verify-identity TLS requires serverHostname") }
            } else {
                guard !(caFile ?? "").isEmpty else { throw CaptureError("\(endpoint) verify-ca TLS requires an explicit caFile") }
                guard hostname == nil || !hostname!.isEmpty else { throw CaptureError("omit \(endpoint) serverHostname or provide a nonempty TLS name") }
            }
        } else {
            guard hostname == nil && caFile == nil && verification == .verifyIdentity else { throw CaptureError("remove \(endpoint) TLS settings when requireTLS is false") }
        }
    }
    public static func configuration(required:Bool,verification:TLSVerification,caFile:String?) -> TLSConfiguration? {
        guard required else { return nil }
        var tls=TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification=verification == .verifyIdentity ? .fullVerification : .noHostnameVerification
        if let caFile { tls.trustRoots = .file(caFile) }
        return tls
    }
}
