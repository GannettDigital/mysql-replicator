import NIOSSL
import ReplicatorCapture

extension TargetConfiguration {
    func tlsConfiguration() -> TLSConfiguration? {
        ConnectionTLS.configuration(required: requireTLS, verification: tlsVerification, caFile: caFile)
    }
}
