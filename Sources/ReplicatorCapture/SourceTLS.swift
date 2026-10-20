import NIOSSL

extension CaptureConfiguration {
    func tlsConfiguration() -> TLSConfiguration? {
        ConnectionTLS.configuration(required: requireTLS, verification: tlsVerification, caFile: caFile)
    }
}
