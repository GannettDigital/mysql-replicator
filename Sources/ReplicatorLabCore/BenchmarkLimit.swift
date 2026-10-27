import Foundation

/// Report-only affects the time limit, never workload or checkpoint assertions.
struct BenchmarkLimit {
    let ratio: Double
    let maximum: Double
    let reportOnly: Bool
    var withinLimit: Bool { ratio <= maximum }
    var accepts: Bool { withinLimit || reportOnly }

    init(nativeSeconds: Double, applierSeconds: Double, maximum: Double, reportOnly: Bool) throws {
        try Self.validate(maximum)
        try require(
            nativeSeconds.isFinite && nativeSeconds > 0 && applierSeconds.isFinite && applierSeconds > 0,
            "benchmark times must be finite and positive")
        ratio = applierSeconds / nativeSeconds
        try require(ratio.isFinite, "benchmark ratio is not finite")
        self.maximum = maximum
        self.reportOnly = reportOnly
    }

    static func validate(_ maximum: Double) throws {
        try require(maximum.isFinite && maximum > 0, "max-native-ratio must be finite and positive")
    }

    var json: [String: Any] {
        [
            "applier_to_native_ratio": ratio, "maximum_ratio": maximum,
            "status": withinLimit ? "within_limit" : "over_limit",
            "policy": reportOnly ? "report-only" : "enforce", "accepted": accepts,
        ]
    }
}
