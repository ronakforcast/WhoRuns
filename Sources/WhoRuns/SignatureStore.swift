import Foundation

struct SigInfo: Codable {
    let authority: String?   // nil => unsigned / invalid
    let teamID: String?
    let mtime: Double
}

/// Verifies non-Apple binaries with `codesign` and caches results on disk,
/// keyed by binary path + modification time, so repeat scans are instant.
actor SignatureStore {

    static let shared = SignatureStore()

    private var cache: [String: SigInfo] = [:]
    private let cacheURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("WhoRuns", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("signatures.json")
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: SigInfo].self, from: data) {
            cache = decoded
        }
    }

    func cachedInfo(forBinaryAt path: String, mtime: Double) -> SigInfo? {
        guard let entry = cache[path], entry.mtime == mtime else { return nil }
        return entry
    }

    func verify(binaryAt path: String, mtime: Double) async -> SigInfo? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Run codesign off the actor so many binaries can be verified concurrently.
        let info = await Task.detached(priority: .utility) {
            Self.runCodesign(binaryAt: path, mtime: mtime)
        }.value
        cache[path] = info
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return info
    }

    private static func runCodesign(binaryAt path: String, mtime: Double) -> SigInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe   // codesign -dv writes to stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return SigInfo(authority: nil, teamID: nil, mtime: mtime)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        var authority: String?
        var teamID: String?
        for line in text.split(separator: "\n") {
            if authority == nil, let range = line.range(of: "Authority=") {
                authority = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if teamID == nil, let range = line.range(of: "TeamIdentifier=") {
                teamID = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return SigInfo(authority: authority, teamID: teamID, mtime: mtime)
    }
}
