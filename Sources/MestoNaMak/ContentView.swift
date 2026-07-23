import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var monitor: DiskMonitorViewModel
    @AppStorage("appLanguage") private var languageCode = AppLanguage.russian.rawValue
    @State private var isShowingAbout = false
    @State private var isConfirmingStop = false

    private var language: AppLanguage { AppLanguage(rawValue: languageCode) ?? .russian }
    private func t(_ key: String, _ arguments: CVarArg...) -> String { tr(key, language: language, arguments) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if monitor.currentSizes.isEmpty && !monitor.isScanning {
                ContentUnavailableView(t("empty.title"), systemImage: "magnifyingglass", description: Text(t("empty.description")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                folderTree
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.locale, language.locale)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { isShowingAbout = true } label: {
                    Label(t("about"), systemImage: "info.circle")
                }
                .help(t("about"))
                languageMenu
            }
        }
        .sheet(isPresented: $isShowingAbout) {
            aboutSheet
        }
        .alert(t("error"), isPresented: Binding(get: { monitor.errorMessage != nil }, set: { if !$0 { monitor.errorMessage = nil } })) {
            Button("OK", role: .cancel) { monitor.errorMessage = nil }
        } message: { Text(monitor.errorMessage ?? "") }
        .confirmationDialog(t("stop.confirm.title"), isPresented: $isConfirmingStop, titleVisibility: .visible) {
            Button(t("stop.scan"), role: .destructive) { monitor.stopScan() }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text(t("stop.confirm.message"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("main.disk")).font(.headline)
                    if let available = monitor.diskAvailable, let capacity = monitor.diskCapacity {
                        Text(t("disk.free", available.formatted(.byteCount(style: .file)), capacity.formatted(.byteCount(style: .file))))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if monitor.isScanning {
                    Button {
                        isConfirmingStop = true
                    } label: {
                        Label(t("stop.scan"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    HStack(spacing: 8) {
                        Button { monitor.scanAndSaveSnapshot(mode: .accelerated) } label: {
                            Label(t("scan.accelerated"), systemImage: "bolt")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { monitor.scanAndSaveSnapshot(mode: .full) } label: {
                            Label(t("scan.full.button"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                Picker(t("sorting"), selection: $monitor.sortMode) {
                    ForEach(SortMode.allCases) { Text(t($0.translationKey)).tag($0) }
                }.pickerStyle(.segmented).frame(width: 210)
                Picker(t("compare"), selection: $monitor.baselineID) {
                    Text(t("no.compare")).tag(UUID?.none)
                    ForEach(monitor.relevantSnapshots) { snapshot in
                        let date = snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)
                        let storage = t("snapshot.storage", monitor.snapshotStorageSizeText(snapshot))
                        Text("\(date) · \(storage)").tag(Optional(snapshot.id))
                    }
                }.frame(width: 270)
                Button(role: .destructive) { monitor.deleteBaselineSnapshot() } label: {
                    Label(t("delete.snapshot"), systemImage: "trash")
                }
                .disabled(monitor.baselineID == nil)
                .help(t("delete.help"))
                Button { monitor.optimizeHistory() } label: {
                    Label(t("optimize.history"), systemImage: "archivebox")
                }
                .disabled(monitor.isOptimizingHistory)
                .help(t("optimize.help"))
                Spacer()
            }

            if monitor.isScanning { scanStatus }
            scanDurationStatus
        }
        .padding()
    }

    private var scanStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(
                    monitor.isPreparingChangeHistory
                        ? t("history.loading")
                        : (monitor.isCounting ? t("counting", monitor.countedEntries.formatted()) : t(monitor.isIncrementalScan ? "scanning.partial" : "scanning.full"))
                )
                Spacer()
                if let remaining = monitor.remainingTimeText {
                    Text(t("remaining", remaining))
                } else if monitor.isCounting, let progress = monitor.countingProgress {
                    Text(monitor.exceededPreviousEntryCount ? t("more.previous") : "≈ \(Int(progress * 100))%")
                } else if let progress = monitor.scanProgress {
                    Text("\(Int(progress * 100))%")
                }
            }
            .font(.caption)
            if monitor.isPreparingChangeHistory {
                ProgressView()
            } else if monitor.isCounting, let progress = monitor.countingProgress {
                ProgressView(value: progress, total: 1)
            } else if monitor.isCounting {
                ProgressView()
            } else if let progress = monitor.scanProgress {
                ProgressView(value: progress, total: 1)
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var scanDurationStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let duration = monitor.formattedScanDuration(at: context.date) {
                HStack(spacing: 5) {
                    Image(systemName: "stopwatch")
                    let key = monitor.isScanning ? "scan.elapsed" : (monitor.lastScanWasIncremental == true ? "scan.last.partial" : "scan.last.full")
                    Text(t(key, duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(AppLanguage.allCases) { option in
                Button(option.shortTitle) { languageCode = option.rawValue }
            }
        } label: {
            Label(language.shortTitle, systemImage: "globe")
        }
        .help("Language / Язык")
    }

    private var aboutSheet: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            Text("DiskPulse for Mac")
                .font(.title2.weight(.semibold))
            Text(t("about.description"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(t("about.author")).foregroundStyle(.secondary)
                    Text("Denis P")
                }
                GridRow {
                    Text(t("about.email")).foregroundStyle(.secondary)
                    Link("307751729+djperov@users.noreply.github.com", destination: URL(string: "mailto:307751729+djperov@users.noreply.github.com")!)
                }
                GridRow {
                    Text(t("about.website")).foregroundStyle(.secondary)
                    Link("djperov.github.io/diskpulse-for-mac", destination: URL(string: "https://djperov.github.io/diskpulse-for-mac/")!)
                }
            }
            Link(t("feedback"), destination: URL(string: "https://github.com/djperov/diskpulse-for-mac/issues")!)
                .buttonStyle(.bordered)
            Button(t("close")) { isShowingAbout = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 430)
    }

    private var folderTree: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t("folder"))
                Spacer()
                Text(t("size")).frame(width: 115, alignment: .trailing)
                Text(t("change")).frame(width: 115, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 7)
            Divider()

            List {
                ForEach(monitor.displayedTree) { node in
                    FolderTreeBranch(node: node, level: 0, language: language, initiallyExpanded: true)
                }
            }
            .listStyle(.inset)
            .overlay {
                if monitor.isUpdatingTree {
                    ProgressView(t("tree.preparing"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct FolderTreeBranch: View {
    @EnvironmentObject private var monitor: DiskMonitorViewModel
    let node: FolderNode
    let level: Int
    let language: AppLanguage
    @State private var isExpanded: Bool
    @State private var isHovered = false

    init(node: FolderNode, level: Int, language: AppLanguage, initiallyExpanded: Bool = false) {
        self.node = node
        self.level = level
        self.language = language
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        Group {
            HStack(spacing: 8) {
                if node.hasChildren {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Image(systemName: node.hasChildren ? "folder.fill" : "folder")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.path == "/" ? tr("main.disk", language: language) : node.name)
                    Text(node.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(node.bytes.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .frame(width: 115, alignment: .trailing)
                Text(node.growth == 0 ? "—" : node.growth.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(node.growth > 0 ? .red : (node.growth < 0 ? .green : .secondary))
                    .frame(width: 115, alignment: .trailing)
            }
            .padding(.leading, CGFloat(level) * 18)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(isHovered ? Color.gray.opacity(0.14) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onHover { isHovered = $0 }
            .contextMenu {
                Button(tr("open.finder", language: language)) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
                }
                Button(tr("copy.path", language: language)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(monitor.copyablePath(for: node.path), forType: .string)
                }
            }
            if isExpanded {
                FolderTreeChildren(parentPath: node.path, level: level + 1, language: language)
            }
        }
    }
}

private struct FolderTreeChildren: View {
    @EnvironmentObject private var monitor: DiskMonitorViewModel
    let parentPath: String
    let level: Int
    let language: AppLanguage

    var body: some View {
        ForEach(monitor.children(of: parentPath)) { node in
            FolderTreeBranch(node: node, level: level, language: language)
        }
    }
}
