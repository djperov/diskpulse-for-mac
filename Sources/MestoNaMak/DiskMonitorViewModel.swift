import Foundation
import AppKit

@MainActor
final class DiskMonitorViewModel: ObservableObject {
    /// Leave enough headroom for macOS and an atomic snapshot write.
    private static let minimumFreeSpaceForSnapshot: Int64 = 2_000_000_000
    private static let maximumSnapshots = 10
    /// The filesystem root represents the whole startup disk on macOS.
    @Published private(set) var rootURL = URL(fileURLWithPath: "/")
    @Published private(set) var currentSizes: [String: Int64] = [:]
    @Published private(set) var snapshots: [Snapshot]
    @Published var baselineID: UUID? { didSet { rebuildTree() } }
    @Published var sortMode: SortMode = .size { didSet { rebuildTree() } }
    @Published private(set) var displayedTree: [FolderNode] = []
    @Published private(set) var isUpdatingTree = false
    @Published private(set) var isScanning = false
    @Published private(set) var isCounting = false
    @Published private(set) var countedEntries = 0
    @Published private(set) var scanProgress: Double?
    @Published private(set) var phaseStartedAt = Date.now
    @Published var errorMessage: String?
    @Published private(set) var isOptimizingHistory = false
    private var scanTask: Task<Void, Never>?

    private let store = SnapshotStore()
    private var treeBuildID = UUID()

    init() {
        snapshots = store.load()
        refreshDiskUsage()
    }

    var relevantSnapshots: [Snapshot] {
        snapshots.filter { $0.rootPath == rootURL.standardizedFileURL.path }.sorted { $0.createdAt > $1.createdAt }
    }

    var baseline: Snapshot? { snapshots.first { $0.id == baselineID } }

    private var expectedEntryCount: Int? {
        relevantSnapshots.first?.scannedEntries
    }

    /// During the preparation pass this is an estimate based on the last scan.
    var countingProgress: Double? {
        guard isCounting, let expectedEntryCount, expectedEntryCount > 0 else { return nil }
        return min(1, Double(countedEntries) / Double(expectedEntryCount))
    }

    var exceededPreviousEntryCount: Bool {
        guard let expectedEntryCount else { return false }
        return countedEntries > expectedEntryCount
    }

    var remainingTimeText: String? {
        let elapsed = Date.now.timeIntervalSince(phaseStartedAt)
        guard elapsed > 1 else { return nil }
        let seconds: TimeInterval?
        if isCounting, let expectedEntryCount, countedEntries > 0, expectedEntryCount > countedEntries {
            let entriesPerSecond = Double(countedEntries) / elapsed
            seconds = Double(expectedEntryCount - countedEntries) / entriesPerSecond
        } else if !isCounting, let scanProgress, scanProgress > 0 {
            seconds = elapsed * (1 - scanProgress) / scanProgress
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 1 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds)
    }

    var diskCapacity: Int64? {
        let values = try? rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map { Int64($0) }
    }

    var diskAvailable: Int64? {
        let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
    }

    var rows: [FolderSize] {
        currentSizes.map { FolderSize(path: $0.key, bytes: $0.value) }.sorted { left, right in
            switch sortMode {
            case .size: return left.bytes == right.bytes ? left.path < right.path : left.bytes > right.bytes
            case .growth:
                let a = growth(for: left.path)
                let b = growth(for: right.path)
                return a == b ? left.path < right.path : a > b
            }
        }
    }

    /// Builds the potentially very large Finder-like hierarchy away from the UI thread.
    nonisolated private static func makeFolderTree(
        sizes: [String: Int64],
        baselineSizes: [String: Int64],
        rootPath: String,
        sortMode: SortMode
    ) -> [FolderNode] {
        guard sizes[rootPath] != nil else { return [] }
        var childrenByParent: [String: [String]] = [:]
        for path in sizes.keys where path != rootPath {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if sizes[parent] != nil {
                childrenByParent[parent, default: []].append(path)
            }
        }

        func compare(_ left: String, _ right: String) -> Bool {
            let growth: (String) -> Int64 = { sizes[$0, default: 0] - baselineSizes[$0, default: 0] }
            switch sortMode {
            case .size:
                let a = sizes[left, default: 0], b = sizes[right, default: 0]
                return a == b ? left.localizedStandardCompare(right) == .orderedAscending : a > b
            case .growth:
                let a = growth(left), b = growth(right)
                return a == b ? left.localizedStandardCompare(right) == .orderedAscending : a > b
            }
        }

        func makeNode(_ path: String) -> FolderNode {
            let childPaths = (childrenByParent[path] ?? []).sorted(by: compare)
            return FolderNode(
                path: path,
                bytes: sizes[path, default: 0],
                growth: sizes[path, default: 0] - baselineSizes[path, default: 0],
                children: childPaths.isEmpty ? nil : childPaths.map(makeNode)
            )
        }
        return [makeNode(rootPath)]
    }

    private func rebuildTree() {
        let buildID = UUID()
        treeBuildID = buildID
        let sizes = currentSizes
        let baselineSizes = baseline?.folderBytes ?? [:]
        let rootPath = rootURL.standardizedFileURL.path
        let mode = sortMode
        guard !sizes.isEmpty else {
            displayedTree = []
            isUpdatingTree = false
            return
        }
        isUpdatingTree = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let tree = Self.makeFolderTree(sizes: sizes, baselineSizes: baselineSizes, rootPath: rootPath, sortMode: mode)
            await self?.applyTree(tree, buildID: buildID)
        }
    }

    private func applyTree(_ tree: [FolderNode], buildID: UUID) {
        guard treeBuildID == buildID else { return }
        displayedTree = tree
        isUpdatingTree = false
    }

    func growth(for path: String) -> Int64 {
        currentSizes[path, default: 0] - (baseline?.folderBytes[path] ?? 0)
    }

    func deleteBaselineSnapshot() {
        guard let id = baselineID else { return }
        snapshots.removeAll { $0.id == id }
        baselineID = nil
        saveSnapshotsInBackground(snapshots)
    }

    func optimizeHistory() {
        guard !isOptimizingHistory else { return }
        isOptimizingHistory = true
        let snapshotsToSave = snapshots
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            do {
                try store.save(snapshotsToSave)
                try store.compact()
                await self?.finishHistoryOptimization()
            } catch {
                await self?.finishHistoryOptimization(error: error)
            }
        }
    }

    func scanAndSaveSnapshot() {
        guard !isScanning else { return }
        isScanning = true
        isCounting = false
        countedEntries = 0
        phaseStartedAt = .now
        scanProgress = nil
        errorMessage = nil
        let root = rootURL
        // The scan itself is read-only. When disk space is low we deliberately
        // skip the history write, so DiskPulse remains useful for freeing space.
        let shouldSaveSnapshot = (diskAvailable ?? 0) >= Self.minimumFreeSpaceForSnapshot
        let task = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let sizes = try await FolderScanner.scan(
                    root: root,
                    estimatedEntryCount: self.expectedEntryCount,
                    progress: { completed, estimatedTotal in await self.updateScanProgress(completed: completed, estimatedTotal: estimatedTotal) }
                )
                self.applyScan(sizes, root: root, shouldSaveSnapshot: shouldSaveSnapshot)
            } catch is CancellationError {
                self.finishScanCancelled()
            } catch {
                self.finishWithError(error)
            }
        }
        scanTask = task
    }

    func stopScan() {
        scanTask?.cancel()
    }

    private func applyScan(_ result: FolderScanner.Result, root: URL, shouldSaveSnapshot: Bool) {
        currentSizes = result.folderBytes
        rebuildTree()
        if shouldSaveSnapshot {
            let snapshot = Snapshot(rootPath: root.path, folderBytes: result.folderBytes, scannedEntries: result.entryCount)
            snapshots.append(snapshot)
            snapshots.sort { $0.createdAt > $1.createdAt }
            snapshots = Array(snapshots.prefix(Self.maximumSnapshots))
            if baselineID == nil { baselineID = relevantSnapshots.dropFirst().first?.id }
            saveSnapshotsInBackground(snapshots)
        } else {
            errorMessage = "На диске меньше 2 ГБ свободного места. Анализ завершён, но снимок истории не сохранён — освободите место и повторите сканирование."
        }
        scanProgress = nil
        isCounting = false
        isScanning = false
        scanTask = nil
    }

    private func finishWithError(_ error: Error) {
        errorMessage = "Не удалось прочитать папку: \(error.localizedDescription)"
        scanProgress = nil
        isCounting = false
        isScanning = false
        scanTask = nil
    }

    private func finishScanCancelled() {
        scanProgress = nil
        isCounting = false
        isScanning = false
        scanTask = nil
    }

    private func updateCount(_ value: Int) { countedEntries = value }

    private func updateScanProgress(completed: Int, estimatedTotal: Int?) {
        if scanProgress == nil { phaseStartedAt = .now }
        countedEntries = completed
        if let estimatedTotal, estimatedTotal > 0 {
            scanProgress = min(1, Double(completed) / Double(estimatedTotal))
        }
    }

    private func refreshDiskUsage() { objectWillChange.send() }

    private func saveSnapshotsInBackground(_ snapshotsToSave: [Snapshot]) {
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            do {
                try store.save(snapshotsToSave)
            } catch {
                await self?.reportSnapshotSaveError(error)
            }
        }
    }

    private func reportSnapshotSaveError(_ error: Error) {
        errorMessage = "Не удалось сохранить историю: \(error.localizedDescription)"
    }

    private func finishHistoryOptimization(error: Error? = nil) {
        isOptimizingHistory = false
        if let error {
            errorMessage = "Не удалось оптимизировать историю: \(error.localizedDescription)"
        }
    }
}
