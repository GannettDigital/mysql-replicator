import Foundation

/// Credential selection is explicit; never include a secret in diagnostics.
public enum PasswordConfiguration {
    public static func validate(password: String?, environmentVariable: String?, endpoint: String) throws {
        guard (password != nil) != (environmentVariable != nil),
              environmentVariable == nil || !environmentVariable!.isEmpty else {
            throw CaptureError("\(endpoint): configure exactly one of password or passwordEnvironment")
        }
    }
    public static func resolve(password: String?, environmentVariable: String?, endpoint: String,
                               environment: [String:String] = ProcessInfo.processInfo.environment) throws -> String {
        try validate(password:password,environmentVariable:environmentVariable,endpoint:endpoint)
        if let password { return password }
        guard let value = environment[environmentVariable!] else {
            throw CaptureError("\(endpoint) password environment variable is unset")
        }
        return value
    }
}
