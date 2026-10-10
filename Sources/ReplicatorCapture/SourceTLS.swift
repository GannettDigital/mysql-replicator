import NIOSSL

extension CaptureConfiguration {
    /// A nil configuration disables TLS, including opportunistic negotiation.
    func tlsConfiguration() -> TLSConfiguration? {
        guard requireTLS else { return nil }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        if let caFile { tls.trustRoots = .file(caFile) }
        return tls
    }
}
