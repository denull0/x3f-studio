import Foundation

/// Per-second counters printed to stderr when the app runs with X3F_DEBUG=1 (launch the binary
/// from a shell): which objects publish and which view bodies re-evaluate.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["X3F_DEBUG"] == "1"
    private static var counts: [String: Int] = [:]
    private static var last = Date()
    private static let lock = NSLock()

    static func tick(_ key: String) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
        let now = Date()
        if now.timeIntervalSince(last) >= 1 {
            let line = counts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            FileHandle.standardError.write(("[x3f] " + line + "\n").data(using: .utf8)!)
            counts = [:]; last = now
        }
    }
}
