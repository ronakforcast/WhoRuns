import SwiftUI
import AppKit

// MARK: - Types

private struct DistEntry: Identifiable {
    let name: String
    let ram: Double
    let fraction: Double
    let color: Color
    let isRest: Bool
    var id: String { name }
}

/// A kill action awaiting user confirmation (kept inline — the menu bar
/// panel can't present system dialogs without dismissing itself).
private enum PendingKill: Equatable {
    case single(ProcInfo)
    case group(OwnerGroup)
}

// MARK: - Panel

/// Performance model: `body` never computes — it renders `displayedGroups`,
/// rebuilt only when the scan, search, filter or sort actually change.
/// Rows are Equatable so unchanged rows skip re-rendering entirely.
struct PanelView: View {
    @ObservedObject var model: AppModel

    @State private var searchText = ""
    @State private var sortBy: SortOrder = .memory
    @State private var filter: ScopeFilter = .all
    @State private var expandedOwners: Set<String> = []

    // Kill flow (inline bar, not dialogs — dialogs dismiss the menu bar window).
    @State private var pendingKill: PendingKill?
    @State private var resultMessage = ""
    @State private var resultIsError = false
    @State private var showResultBanner = false
    @State private var resultID = 0

    // Cached display state — the single source for list + distribution bar.
    @State private var displayedGroups: [OwnerGroup] = []
    @State private var distEntries: [DistEntry] = []
    @State private var rebuildTask: Task<Void, Never>?

    enum SortOrder: String, CaseIterable, Identifiable {
        case memory = "Memory"
        case cpu = "CPU"
        case name = "Name"
        var id: String { rawValue }
    }

    enum ScopeFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case apps = "Apps"
        case system = "System"
        var id: String { rawValue }
    }

    private static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .yellow]

    // MARK: Body

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                dashboardHeader
                filterBar
                Divider()
                if model.groups.isEmpty && model.lastUpdated == nil {
                    loadingState
                } else if displayedGroups.isEmpty {
                    emptyState
                } else {
                    contentList
                }
            }
            if pendingKill != nil {
                confirmBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showResultBanner {
                resultBar
                    .id(resultID)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: pendingKill)
        .animation(.easeInOut(duration: 0.18), value: showResultBanner)
        .onAppear {
            model.panelVisible = true
            rebuildDisplayed()
            Task { await model.rescan() }
        }
        .onDisappear { model.panelVisible = false }
        .onChange(of: model.lastUpdated) { _ in rebuildDisplayed() }
        .onChange(of: filter) { _ in rebuildDisplayed() }
        .onChange(of: sortBy) { _ in rebuildDisplayed() }
        .onChange(of: searchText) { _ in
            // Debounced search: rebuild at most ~8x/second while typing.
            rebuildTask?.cancel()
            rebuildTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                rebuildDisplayed()
            }
        }
        .task {
            // Refresh every 30 seconds while the panel is open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                await model.rescan()
            }
        }
    }

    // MARK: - Inline confirm / result bars

    private var confirmBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(pendingKillTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") {
                    withAnimation { pendingKill = nil }
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                Button("Kill") {
                    executePendingKill()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var pendingKillTitle: String {
        switch pendingKill {
        case .single(let p):
            return "Kill \(p.name) (PID \(p.id))? Unsaved data may be lost."
        case .group(let g):
            return "Kill all \(g.procs.count) processes owned by \(g.name)? Unsaved data may be lost."
        case nil:
            return ""
        }
    }

    private var resultBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: resultIsError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(resultIsError ? .orange : .green)
                Text(resultMessage)
                    .font(.system(size: 11))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("OK") {
                    withAnimation { showResultBanner = false }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .task {
            // Auto-dismiss after 6 seconds.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled {
                withAnimation { showResultBanner = false }
            }
        }
    }

    private func executePendingKill() {
        switch pendingKill {
        case .single(let target):
            resultMessage = model.terminate(target)
            resultIsError = resultMessage.hasPrefix("Could not")
        case .group(let group):
            let outcome = model.terminateAll(group.procs)
            var text = "Killed \(outcome.killedCount) of \(group.procs.count) processes owned by \(group.name)."
            resultIsError = !outcome.failures.isEmpty
            if !outcome.failures.isEmpty {
                let list = outcome.failures.prefix(4).map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
                text += "\nFailed:\n" + list
                if outcome.failures.count > 4 {
                    text += "\n…and \(outcome.failures.count - 4) more"
                }
            }
            resultMessage = text
        case nil:
            return
        }
        resultID += 1
        withAnimation {
            pendingKill = nil
            showResultBanner = true
        }
        Task { await model.rescan() }
    }

    // MARK: - Display-state builder (the ONLY place grouping/filtering happens)

    private func rebuildDisplayed() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        var source = model.groups
        switch filter {
        case .all: break
        case .apps: source = source.filter { $0.name != "Apple" }
        case .system: source = source.filter { $0.name == "Apple" }
        }

        var result: [OwnerGroup] = []
        for group in source {
            var procs = group.procs
            if sortBy != .memory {
                procs = sortedProcs(procs)
            }
            if !query.isEmpty {
                procs = procs.filter { matches($0, query: query) }
            }
            if !procs.isEmpty {
                result.append(OwnerGroup(name: group.name, procs: procs))
            }
        }
        displayedGroups = result
        distEntries = buildDistEntries()
    }

    private func matches(_ proc: ProcInfo, query: String) -> Bool {
        proc.name.lowercased().contains(query)
            || proc.path.lowercased().contains(query)
            || proc.owner.lowercased().contains(query)
            || proc.user.lowercased().contains(query)
            || String(proc.id) == query
    }

    private func buildDistEntries() -> [DistEntry] {
        let total = max(model.totalRAM, 1)
        var entries: [DistEntry] = []
        var restRAM: Double = 0
        for (index, group) in model.groups.enumerated() {
            if index < 7 {
                let color: Color = group.name == "Apple" ? .gray : Self.palette[index % Self.palette.count]
                entries.append(DistEntry(name: group.name, ram: group.totalRAM,
                                         fraction: group.totalRAM / total, color: color, isRest: false))
            } else {
                restRAM += group.totalRAM
            }
        }
        if restRAM > 0 {
            entries.append(DistEntry(name: "Other", ram: restRAM,
                                     fraction: restRAM / total, color: Color.secondary.opacity(0.45), isRest: true))
        }
        return entries
    }

    // MARK: - Dashboard header

    private var dashboardHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("WhoRuns").font(.system(size: 16, weight: .heavy))
                    if let updated = model.lastUpdated {
                        Text("updated \(updated, style: .time)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                statChip(icon: "square.grid.2x2", value: "\(model.procs.count)", label: "processes")
                statChip(icon: "cpu.fill",
                         value: String(format: "%.0f%%", model.totalCPU),
                         label: "CPU",
                         tint: cpuTint(model.totalCPU))
                statChip(icon: "memorychip.fill",
                         value: formatGB(model.totalRAM),
                         label: "RAM",
                         tint: .purple)
                Button {
                    Task { await model.rescan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.quinary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Rescan now")
            }
            ramDistribution
        }
        .padding(12)
    }

    private func statChip(icon: String, value: String, label: String, tint: Color = .accentColor) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(.quinary))
        .help("\(label): \(value)")
    }

    /// Segmented bar showing each owner's share of total RAM, with a top-3 legend.
    private var ramDistribution: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(distEntries) { entry in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(entry.color)
                            .frame(width: geo.size.width * entry.fraction)
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 10) {
                ForEach(distEntries.filter { !$0.isRest }.prefix(3)) { entry in
                    HStack(spacing: 4) {
                        Circle().fill(entry.color).frame(width: 6, height: 6)
                        Text("\(entry.name) \(formatMB(entry.ram))")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("RAM by owner")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search name, path, owner, PID…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            Picker("Scope", selection: $filter) {
                ForEach(ScopeFilter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            Picker("Sort", selection: $sortBy) {
                ForEach(SortOrder.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 88)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    private var contentList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(displayedGroups) { group in
                    ownerCard(group)
                }
            }
            .padding(12)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Scanning processes…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text("No processes match").font(.system(size: 13, weight: .semibold))
            Text("Try a different search or filter.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Owner card

    private func ownerCard(_ group: OwnerGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GroupIconView(owner: group.name, representativePath: group.procs.first?.path, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.name)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                        signatureBadge(group)
                    }
                    Text("\(group.procs.count) procs · \(formatMB(group.totalRAM)) · \(String(format: "%.1f%%", group.totalCPU)) CPU")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                killAllControl(group)
                Button {
                    toggleExpanded(group)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Show processes")
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 7)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded(group) }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    Capsule().fill(Color.accentColor.opacity(0.55))
                        .frame(width: geo.size.width * ramFraction(group))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 10)
            .padding(.bottom, isExpanded(group) ? 0 : 9)

            if isExpanded(group) {
                VStack(spacing: 0) {
                    ForEach(group.procs) { proc in
                        ProcRowView(proc: proc,
                                    sig: model.status(for: proc)) { target in
                            withAnimation { pendingKill = .single(target) }
                        }
                        .equatable()
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.quinary.opacity(0.55)))
        .animation(.easeInOut(duration: 0.18), value: expandedOwners)
    }

    @ViewBuilder
    private func killAllControl(_ group: OwnerGroup) -> some View {
        if group.name == "Apple" {
            Label("Kill all", systemImage: "xmark.bin")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.quaternary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quinary))
                .help("System processes can't be bulk-killed for safety")
        } else {
            Button {
                withAnimation { pendingKill = .group(group) }
            } label: {
                Label("Kill all", systemImage: "xmark.bin")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.red.opacity(0.1)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Kill all \(group.procs.count) processes owned by \(group.name)")
        }
    }

    @ViewBuilder
    private func signatureBadge(_ group: OwnerGroup) -> some View {
        if group.name == "Apple" {
            EmptyView()
        } else {
            let unsigned = group.procs.filter { proc in
                if case .unsigned = model.status(for: proc) { return true }
                return false
            }.count
            if unsigned > 0 {
                Label("\(unsigned) unsigned", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red)
            } else if !group.procs.contains(where: isUnchecked) {
                Label("signed", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Label("verifying…", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private func sortedProcs(_ procs: [ProcInfo]) -> [ProcInfo] {
        switch sortBy {
        case .memory:
            return procs
        case .cpu:
            return procs.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.name < $1.name }
        case .name:
            return procs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func isExpanded(_ group: OwnerGroup) -> Bool {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return expandedOwners.contains(group.name)
    }

    private func toggleExpanded(_ group: OwnerGroup) {
        if expandedOwners.contains(group.name) {
            expandedOwners.remove(group.name)
        } else {
            expandedOwners.insert(group.name)
        }
    }

    private func isUnchecked(_ proc: ProcInfo) -> Bool {
        if case .checking = model.status(for: proc) { return true }
        return false
    }

    // MARK: - Formatting

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    private func formatGB(_ mb: Double) -> String {
        String(format: "%.1f GB", mb / 1024)
    }

    private func cpuTint(_ cpu: Double) -> Color {
        if cpu > 50 { return .red }
        if cpu > 10 { return .orange }
        return .accentColor
    }

    private func ramFraction(_ group: OwnerGroup) -> Double {
        let total = max(model.totalRAM, 1)
        return min(group.totalRAM / total, 1)
    }
}

// MARK: - Process row (Equatable: unchanged rows are never re-rendered)

private struct ProcRowView: View, Equatable {
    let proc: ProcInfo
    let sig: SigStatus
    let onKill: (ProcInfo) -> Void

    static func == (lhs: ProcRowView, rhs: ProcRowView) -> Bool {
        lhs.proc == rhs.proc && lhs.sig == rhs.sig
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(proc.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("PID \(proc.id)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(proc.user)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(String(format: "%.1f%%", proc.cpu))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(cpuTint(proc.cpu))
                        .frame(width: 48, alignment: .trailing)
                    Text(formatMB(proc.rssMB))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                Text(proc.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                signatureLine
            }
            Button {
                onKill(proc)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.red.opacity(0.6))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.red.opacity(0.08)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Kill \(proc.name) (PID \(proc.id))")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var signatureLine: some View {
        switch sig {
        case .apple:
            Text("Apple system binary")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        case .checking:
            Text("verifying signature…")
                .font(.system(size: 9.5))
                .italic()
                .foregroundStyle(.tertiary)
        case .signed(let authority):
            Text("✓ \(prettyAuthority(authority))")
                .font(.system(size: 9.5))
                .foregroundStyle(.green)
        case .unsigned:
            Text("⚠ UNSIGNED")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.red)
        }
    }

    private func prettyAuthority(_ authority: String) -> String {
        var a = authority
        for prefix in ["Developer ID Application: ",
                       "Apple Mac OS Application Signing: ",
                       "Apple Development: ",
                       "Apple Application Signing: "] {
            if a.hasPrefix(prefix) {
                a = String(a.dropFirst(prefix.count))
                break
            }
        }
        if let range = a.range(of: #"\s*\([A-Z0-9]{10}\)$"#, options: .regularExpression) {
            a = String(a[..<range.lowerBound])
        }
        return a
    }

    private func cpuTint(_ cpu: Double) -> Color {
        if cpu > 50 { return .red }
        if cpu > 10 { return .orange }
        return .accentColor
    }

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}
