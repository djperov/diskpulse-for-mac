import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var monitor: DiskMonitorViewModel
    @AppStorage("appLanguage") private var languageCode = AppLanguage.russian.rawValue

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
                languageMenu
                Button(monitor.isScanning ? t("stop.scan") : t("scan"), systemImage: monitor.isScanning ? "stop.fill" : "arrow.clockwise") {
                    monitor.isScanning ? monitor.stopScan() : monitor.scanAndSaveSnapshot()
                }
            }
        }
        .alert(t("error"), isPresented: Binding(get: { monitor.errorMessage != nil }, set: { if !$0 { monitor.errorMessage = nil } })) {
            Button("OK", role: .cancel) { monitor.errorMessage = nil }
        } message: { Text(monitor.errorMessage ?? "") }
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
                Button { monitor.isScanning ? monitor.stopScan() : monitor.scanAndSaveSnapshot() } label: {
                    Label(monitor.isScanning ? t("stop.scan") : t("scan"), systemImage: monitor.isScanning ? "stop.fill" : "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(monitor.isScanning ? .red : .accentColor)
            }

            HStack {
                Picker(t("sorting"), selection: $monitor.sortMode) {
                    ForEach(SortMode.allCases) { Text(t($0.translationKey)).tag($0) }
                }.pickerStyle(.segmented).frame(width: 210)
                Picker(t("compare"), selection: $monitor.baselineID) {
                    Text(t("no.compare")).tag(UUID?.none)
                    ForEach(monitor.relevantSnapshots) { snapshot in
                        Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)).tag(Optional(snapshot.id))
                    }
                }.frame(width: 190)
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
        }
        .padding()
    }

    private var scanStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(monitor.isCounting ? t("counting", monitor.countedEntries.formatted()) : t("scanning.disk"))
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
            if monitor.isCounting, let progress = monitor.countingProgress {
                ProgressView(value: progress, total: 1)
            } else if monitor.isCounting {
                ProgressView()
            } else {
                ProgressView(value: monitor.scanProgress ?? 0, total: 1)
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
                OutlineGroup(monitor.displayedTree, children: \.children) { node in
                    FolderTreeRow(node: node, language: language)
                }
            }
            .listStyle(.inset)
            .overlay {
                if monitor.isUpdatingTree {
                    ProgressView(t("sorting.progress"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct FolderTreeRow: View {
    let node: FolderNode
    let language: AppLanguage
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.children == nil ? "folder" : "folder.fill")
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
        }
    }
}
