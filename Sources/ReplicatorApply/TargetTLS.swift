import NIOSSL

extension TargetConfiguration {
    /// Called after configuration validation; verify-ca still verifies the chain
    /// against the explicit CA file. It only omits the certificate name check.
    func tlsConfiguration() -> TLSConfiguration? {
        guard requireTLS else { return nil }
        var tls = TLSConfiguration.makeClientConfiguration()
        switch tlsVerification {
        case .verifyIdentity: tls.certificateVerification = .fullVerification
        case .verifyCA: tls.certificateVerification = .noHostnameVerification
        }
        if let caFile { tls.trustRoots = .file(caFile) }
        return tls
    }
}
