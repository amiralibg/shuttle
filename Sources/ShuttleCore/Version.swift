import Foundation

public enum ShuttleVersion {
    public static let current = "0.1.0"

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let trimmed = v.hasPrefix("v") ? String(v.dropFirst()) : v
            let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    public static var full: String {
        var out = "shuttle \(current)"
        #if arch(arm64)
            out += " (arm64)"
        #elseif arch(x86_64)
            out += " (x86_64)"
        #endif
        return out
    }
}
