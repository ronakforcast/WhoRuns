import Foundation

struct ProcInfo: Identifiable, Hashable {
    let id: Int32          // pid
    let ppid: Int32
    let user: String
    let cpu: Double
    let rssMB: Double
    let path: String
    let owner: String
    let name: String
}

/// A group of processes belonging to one owner (app / vendor / system).
struct OwnerGroup: Identifiable, Equatable {
    let name: String
    let procs: [ProcInfo]
    var id: String { name }
    var totalRAM: Double { procs.reduce(0) { $0 + $1.rssMB } }
    var totalCPU: Double { procs.reduce(0) { $0 + $1.cpu } }
}

/// Enumerates running processes via `ps` and attributes each one to an owner,
/// mirroring the audit logic (system paths -> Apple, .app bundles -> app name, etc.).
enum ProcScanner {

    static func scan() -> [ProcInfo] {
        parse(runPS())
    }

    private static func runPS() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,user=,%cpu=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parse(_ output: String) -> [ProcInfo] {
        var procs: [ProcInfo] = []
        procs.reserveCapacity(700)
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let tokens = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 6,
                  let pid = Int32(tokens[0]),
                  let ppid = Int32(tokens[1]),
                  let cpu = Double(tokens[3]),
                  let rss = Double(tokens[4])
            else { continue }
            let user = String(tokens[2])
            // Executable path is everything after the first 5 fields (paths may contain spaces).
            let path = tokens[5...].map(String.init).joined(separator: " ")
            procs.append(ProcInfo(
                id: pid,
                ppid: ppid,
                user: user,
                cpu: cpu,
                rssMB: rss / 1024.0,
                path: path,
                owner: owner(ofPath: path),
                name: name(ofPath: path)
            ))
        }
        return procs
    }

    static func name(ofPath path: String) -> String {
        guard let last = path.split(separator: "/").last, !last.isEmpty else { return path }
        return String(last)
    }

    static func owner(ofPath path: String) -> String {
        // kernel_task and similar bare names
        if !path.contains("/") { return "Apple" }
        let systemPrefixes = ["/System/", "/usr/libexec", "/usr/sbin", "/usr/bin", "/sbin/", "/bin/"]
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) {
            return "Apple"
        }
        if let app = firstAppComponent(of: path) {
            return app
        }
        if path.hasPrefix("/Library/") {
            let comps = path.split(separator: "/")
            return comps.count >= 2 ? "Library: \(comps[1])" : "Library"
        }
        if path.hasPrefix("/Applications/") { return "Applications" }
        if path.hasPrefix("/opt/homebrew/") { return "Homebrew" }
        if path.hasPrefix("/usr/local/") { return "/usr/local" }
        if path.hasPrefix("/Users/") { return "User-level" }
        return "Other"
    }

    private static func firstAppComponent(of path: String) -> String? {
        for comp in path.split(separator: "/") where comp.hasSuffix(".app") {
            return String(comp.dropLast(4))
        }
        return nil
    }

    /// Groups processes by owner, sorted by RAM (groups and members).
    /// Computed once per scan so SwiftUI bodies never pay for grouping.
    static func groupByOwner(_ procs: [ProcInfo]) -> [OwnerGroup] {
        Dictionary(grouping: procs, by: \ProcInfo.owner)
            .map { pair in
                OwnerGroup(
                    name: pair.key,
                    procs: pair.value.sorted { $0.rssMB != $1.rssMB ? $0.rssMB > $1.rssMB : $0.name < $1.name }
                )
            }
            .sorted { $0.totalRAM > $1.totalRAM }
    }
}
