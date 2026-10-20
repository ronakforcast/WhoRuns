import SwiftUI
import AppKit

enum SigStatus: Equatable {
    case apple
    case checking
    case signed(String)
    case unsigned
}

@MainActor
final class AppModel: ObservableObject {

    // Raw + precomputed data, populated once per scan.
    @Published var procs: [ProcInfo] = []
    @Published var groups: [OwnerGroup] = []
    @Published var signatures: [String: SigInfo] = [:]
    @Published var panelVisible = false
    @Published var lastUpdated: Date?
    @Published var totalCPU: Double = 0
    @Published var totalRAM: Double = 0

    private var pending = Set<String>()
    private var stagedSignatures: [String: SigInfo] = [:]
    private var flushTask: Task<Void, Never>?

    func rescan() async {
        let scanned = await Task.detached(priority: .userInitiated) {
            ProcScanner.scan()
        }.value
        procs = scanned
        totalCPU = scanned.reduce(0) { $0 + $1.cpu }
        totalRAM = scanned.reduce(0) { $0 + $1.rssMB }
        groups = ProcScanner.groupByOwner(scanned)
        lastUpdated = Date()
        verifySignatures(for: scanned)
    }

    func status(for proc: ProcInfo) -> SigStatus {
        if proc.owner == "Apple" { return .apple }
        if let info = signatures[proc.path] {
            if let authority = info.authority { return .signed(authority) }
            return .unsigned
        }
        return .checking
    }

    @discardableResult
    func terminate(_ proc: ProcInfo) -> String {
        if Darwin.kill(proc.id, SIGTERM) == 0 {
            return "Sent SIGTERM to \(proc.name) (PID \(proc.id))."
        }
        let code = errno
        let reason = String(cString: strerror(code))
        return "Could not kill \(proc.name) (PID \(proc.id)): \(reason)"
    }

    struct KillOutcome {
        let killedCount: Int
        let failures: [(name: String, reason: String)]
    }

    @discardableResult
    func terminateAll(_ procs: [ProcInfo]) -> KillOutcome {
        var killed = 0
        var failures: [(name: String, reason: String)] = []
        for proc in procs {
            if Darwin.kill(proc.id, SIGTERM) == 0 {
                killed += 1
            } else {
                failures.append((name: proc.name, reason: String(cString: strerror(errno))))
            }
        }
        return KillOutcome(killedCount: killed, failures: failures)
    }

    // MARK: - Signature verification

    /// Kicks off verification for every unseen non-Apple binary.
    /// Results are staged and flushed in batches so the UI re-renders a handful of
    /// times per burst instead of once per binary.
    private func verifySignatures(for procs: [ProcInfo]) {
        let paths = Set(procs.filter { $0.owner != "Apple" }.map { $0.path })
        for path in paths where !pending.contains(path)
            && signatures[path] == nil
            && stagedSignatures[path] == nil {
            pending.insert(path)
            Task { [weak self] in
                guard let self else { return }
                let mtime = Self.mtime(ofBinaryAt: path)
                var info = await SignatureStore.shared.cachedInfo(forBinaryAt: path, mtime: mtime)
                if info == nil {
                    info = await SignatureStore.shared.verify(binaryAt: path, mtime: mtime)
                }
                if let info {
                    self.stageSignature(path, info)
                }
                self.pending.remove(path)
            }
        }
    }

    private func stageSignature(_ path: String, _ info: SigInfo) {
        stagedSignatures[path] = info
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            let staged = self.stagedSignatures
            self.stagedSignatures.removeAll()
            if !staged.isEmpty {
                self.signatures.merge(staged) { _, new in new }
            }
        }
    }

    nonisolated private static func mtime(ofBinaryAt path: String) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let date = attrs?[.modificationDate] as? Date {
            return date.timeIntervalSince1970
        }
        return 0
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    }
}

@main
struct WhoRunsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
                .frame(width: 560, height: 640)
        } label: {
            if model.panelVisible {
                HStack(spacing: 3) {
                    Image(systemName: "scope")
                    Text("\(model.procs.count)").monospacedDigit()
                }
            } else {
                Image(systemName: "scope")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
