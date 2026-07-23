import Foundation
import AppKit

@MainActor
final class DiskMonitorViewModel: ObservableObject {
    /// Leave enough headroom for macOS and an atomic snapshot write.
    private static let minimumFreeSpaceForSnapshot: Int64 = 2_000_000_000
    private static let maximumSnapshots = 10
    private static let lastFullScanDurationKey = "lastFullScanDuration"
    /// The filesystem root represents the whole startup disk on macOS.
    @Published private(set) var rootURL = URL(fileURLWithPath: "/")
    @Published private(set) var currentSizes: [String: Int64] = [:]
    @Published private(set) var snapshots: [Snapshot]
    @Published var baselineID: UUID? { didSet { rebuildTree() } }
    @Published var sortMode: SortMode = .size { didSet { rebuildTree() } }
    @Published private(set) var displayedTree: [FolderNode] = []
    @Published private(set) var isUpdatingTree = false
    @Published private(set) var isScanning = false
    @Published private(set) var isIncrementalScan = false
    @Published private(set) var isPreparingChangeHistory = false
    @Published private(set) var isCounting = false
    @Published private(set) var countedEntries = 0
    @Published private(set) var scanProgress: Double?
    @Published private(set) var lastScanDuration: TimeInterval?
    @Published private(set) var lastScanWasIncremental: Bool?
    @Published private(set) var phaseStartedAt = Date.now
    @Published var errorMessage: String?
    @Published private(set) var isOptimizingHistory = false
    private var scanTask: Task<Void, Never>?
    private var scanStartedAt: Date?
    private var progressSamples: [(date: Date, entries: Int)] = []
    private var previousFullScanDuration: TimeInterval?

    private let store = SnapshotStore()
    private var changeTracker: FileChangeTracker!
    private var treeBuildID = UUID()
    private var childPathsByParent: [String: [String]] = [:]

    init() {
        snapshots = store.load()
        let storedDuration = UserDefaults.standard.double(forKey: Self.lastFullScanDurationKey)
        previousFullScanDuration = storedDuration > 0 ? storedDuration : nil
        baselineID = snapshots
            .filter { $0.rootPath == rootURL.standardizedFileURL.path }
            .max { $0.createdAt < $1.createdAt }?
            .id
        changeTracker = FileChangeTracker(
            rootURL: rootURL,
            checkpoint: store.loadCheckpoint(rootPath: rootURL.standardizedFileURL.path)
        )
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
        let seconds: TimeInterval?
        guard !isPreparingChangeHistory, !isIncrementalScan else { return nil }
        let historicalRemaining: TimeInterval? = {
            guard let previousFullScanDuration, let scanProgress else { return nil }
            return previousFullScanDuration * max(0, 1 - scanProgress)
        }()
        if let expectedEntryCount, countedEntries > 0, expectedEntryCount > countedEntries, progressSamples.count >= 2 {
            let first = progressSamples[0]
            let latest = progressSamples[progressSamples.count - 1]
            let elapsed = latest.date.timeIntervalSince(first.date)
            let processed = latest.entries - first.entries
            if elapsed > 0.5, processed > 0 {
                let basedOnCurrentSpeed = Double(expectedEntryCount - countedEntries) / (Double(processed) / elapsed)
                // Directory contents vary wildly in read cost. The slower of
                // the live and previous-full-scan estimates is less misleading.
                seconds = max(basedOnCurrentSpeed, historicalRemaining ?? 0)
            } else {
                seconds = historicalRemaining
            }
        } else {
            seconds = historicalRemaining
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

    /// A path intended for people to paste into a message or Finder's Go to
    /// Folder field. Unlike POSIX `/Users/...`, it starts with the volume name.
    func copyablePath(for path: String) -> String {
        let values = try? rootURL.resourceValues(forKeys: [.volumeNameKey])
        let volumeName = values?.volumeName ?? "Macintosh HD"
        return path == "/" ? volumeName : volumeName + path
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

    func snapshotStorageSizeText(_ snapshot: Snapshot) -> String {
        guard let storageBytes = snapshot.storageBytes else { return "…" }
        return Int64(storageBytes).formatted(.byteCount(style: .file))
    }

    /// Builds only an index in the background. Rows themselves are created
    /// lazily as the user opens a branch, avoiding a long post-scan pause.
    nonisolated private static func makeTreeIndex(sizes: [String: Int64], rootPath: String) -> [String: [String]] {
        var childrenByParent: [String: [String]] = [:]
        for path in sizes.keys where path != rootPath {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if sizes[parent] != nil {
                childrenByParent[parent, default: []].append(path)
            }
        }
        return childrenByParent
    }

    private func nodes(for parent: String) -> [FolderNode] {
        let baselineSizes = baseline?.folderBytes ?? [:]
        let paths = childPathsByParent[parent] ?? []
        let sorted = paths.sorted { left, right in
            let growth: (String) -> Int64 = { self.currentSizes[$0, default: 0] - baselineSizes[$0, default: 0] }
            switch sortMode {
            case .size:
                let a = currentSizes[left, default: 0], b = currentSizes[right, default: 0]
                return a == b ? left.localizedStandardCompare(right) == .orderedAscending : a > b
            case .growth:
                let a = growth(left), b = growth(right)
                return a == b ? left.localizedStandardCompare(right) == .orderedAscending : a > b
            }
        }
        return sorted.map { path in
            FolderNode(
                path: path,
                bytes: currentSizes[path, default: 0],
                growth: currentSizes[path, default: 0] - baselineSizes[path, default: 0],
                hasChildren: !(childPathsByParent[path] ?? []).isEmpty
            )
        }
    }

    private func rebuildTree() {
        let buildID = UUID()
        treeBuildID = buildID
        let sizes = currentSizes
        let baselineSizes = baseline?.folderBytes ?? [:]
        let rootPath = rootURL.standardizedFileURL.path
        guard !sizes.isEmpty else {
            displayedTree = []
            childPathsByParent = [:]
            isUpdatingTree = false
            return
        }
        if !childPathsByParent.isEmpty {
            displayedTree = [FolderNode(path: rootPath, bytes: sizes[rootPath, default: 0], growth: sizes[rootPath, default: 0] - baselineSizes[rootPath, default: 0], hasChildren: true)]
            return
        }
        isUpdatingTree = true
        // Show the disk root immediately while the lightweight index is made.
        displayedTree = [FolderNode(path: rootPath, bytes: sizes[rootPath, default: 0], growth: sizes[rootPath, default: 0] - baselineSizes[rootPath, default: 0], hasChildren: true)]
        Task.detached(priority: .userInitiated) { [weak self] in
            let index = Self.makeTreeIndex(sizes: sizes, rootPath: rootPath)
            await self?.applyTreeIndex(index, buildID: buildID)
        }
    }

    private func applyTreeIndex(_ index: [String: [String]], buildID: UUID) {
        guard treeBuildID == buildID else { return }
        childPathsByParent = index
        let rootPath = rootURL.standardizedFileURL.path
        let baselineSizes = baseline?.folderBytes ?? [:]
        displayedTree = [FolderNode(path: rootPath, bytes: currentSizes[rootPath, default: 0], growth: currentSizes[rootPath, default: 0] - baselineSizes[rootPath, default: 0], hasChildren: !(index[rootPath] ?? []).isEmpty)]
        isUpdatingTree = false
    }

    func children(of path: String) -> [FolderNode] { nodes(for: path) }

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
        Task.detached(priority: .utility) { [weak self] in
            do {
                // SQLite connections are thread-affine in this runtime. A
                // background task owns its own connection instead of sharing
                // the one used to load the initial history on the main actor.
                let backgroundStore = SnapshotStore()
                _ = try backgroundStore.save(snapshotsToSave)
                try backgroundStore.compact()
                await self?.finishHistoryOptimization()
            } catch {
                await self?.finishHistoryOptimization(error: error)
            }
        }
    }

    func scanAndSaveSnapshot(mode: ScanMode = .accelerated) {
        guard !isScanning else { return }
        isScanning = true
        isCounting = false
        countedEntries = 0
        phaseStartedAt = .now
        scanStartedAt = .now
        scanProgress = nil
        progressSamples = []
        errorMessage = nil
        let root = rootURL
        let previousSizes = currentSizes.isEmpty ? (relevantSnapshots.first?.folderBytes ?? [:]) : currentSizes
        let previousEntryCount = expectedEntryCount
        isPreparingChangeHistory = mode == .accelerated && !previousSizes.isEmpty
        // The scan itself is read-only. When disk space is low we deliberately
        // skip the history write, so DiskPulse remains useful for freeing space.
        let shouldSaveSnapshot = (diskAvailable ?? 0) >= Self.minimumFreeSpaceForSnapshot
        let task = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                if mode == .accelerated { await self.changeTracker.waitForHistory() }
                try Task.checkCancellation()
                self.isPreparingChangeHistory = false
                let plan = mode == .accelerated ? self.changeTracker.plan() : nil
                let changedRoots = plan.flatMap {
                    Self.incrementalRoots(for: $0.changedPaths, root: root)
                }
                let usesIncrementalScan = mode == .accelerated && !previousSizes.isEmpty && changedRoots != nil
                self.isIncrementalScan = usesIncrementalScan
                // Capture the event ID before starting a full scan. Events
                // occurring during it are deliberately left for the next run.
                let checkpoint = usesIncrementalScan
                    ? ScanCheckpoint(rootPath: root.standardizedFileURL.path, eventID: plan!.eventID)
                    : self.changeTracker.fullScanCheckpoint()
                let result: FolderScanner.Result
                if let changedRoots {
                    result = try await Self.refreshChangedFolders(
                        changedRoots,
                        previousSizes: previousSizes,
                        previousEntryCount: previousEntryCount,
                        progress: { completed, estimatedTotal in
                            await self.updateScanProgress(completed: completed, estimatedTotal: estimatedTotal)
                        }
                    )
                } else {
                    result = try await FolderScanner.scan(
                        root: root,
                        estimatedEntryCount: previousEntryCount,
                        progress: { completed, estimatedTotal in
                            await self.updateScanProgress(completed: completed, estimatedTotal: estimatedTotal)
                        }
                    )
                }
                self.applyScan(result, root: root, shouldSaveSnapshot: shouldSaveSnapshot, checkpoint: checkpoint)
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

    private func applyScan(_ result: FolderScanner.Result, root: URL, shouldSaveSnapshot: Bool, checkpoint: ScanCheckpoint) {
        currentSizes = result.folderBytes
        childPathsByParent = [:]
        rebuildTree()
        if shouldSaveSnapshot {
            let snapshot = Snapshot(rootPath: root.path, folderBytes: result.folderBytes, scannedEntries: result.entryCount)
            snapshots.append(snapshot)
            snapshots.sort { $0.createdAt > $1.createdAt }
            snapshots = Array(snapshots.prefix(Self.maximumSnapshots))
            if baselineID == nil { baselineID = relevantSnapshots.dropFirst().first?.id }
            saveSnapshotsInBackground(snapshots, checkpoint: checkpoint)
        } else {
            errorMessage = "На диске меньше 2 ГБ свободного места. Анализ завершён, но снимок истории не сохранён — освободите место и повторите сканирование."
        }
        scanProgress = nil
        isCounting = false
        isPreparingChangeHistory = false
        lastScanWasIncremental = isIncrementalScan
        isIncrementalScan = false
        isScanning = false
        finishScanDuration()
        scanTask = nil
    }

    private func finishWithError(_ error: Error) {
        errorMessage = "Не удалось прочитать папку: \(error.localizedDescription)"
        scanProgress = nil
        isCounting = false
        isPreparingChangeHistory = false
        isIncrementalScan = false
        isScanning = false
        finishScanDuration()
        scanTask = nil
    }

    private func finishScanCancelled() {
        scanProgress = nil
        isCounting = false
        isPreparingChangeHistory = false
        isIncrementalScan = false
        isScanning = false
        finishScanDuration()
        scanTask = nil
    }

    private func updateCount(_ value: Int) { countedEntries = value }

    private func updateScanProgress(completed: Int, estimatedTotal: Int?) {
        if scanProgress == nil { phaseStartedAt = .now }
        countedEntries = completed
        let now = Date.now
        progressSamples.append((now, completed))
        progressSamples.removeAll { now.timeIntervalSince($0.date) > 20 }
        if let estimatedTotal, estimatedTotal > 0 {
            // Keep a little room for folder-size aggregation, so the UI never
            // claims 100% while that final work is still taking place.
            scanProgress = min(0.99, Double(completed) / Double(estimatedTotal))
        }
    }

    /// `TimelineView` supplies the current time while scanning, so this value
    /// updates each second without tying a timer to the scanning work itself.
    func formattedScanDuration(at date: Date = .now) -> String? {
        let duration: TimeInterval?
        if isScanning, let scanStartedAt {
            duration = date.timeIntervalSince(scanStartedAt)
        } else {
            duration = lastScanDuration
        }
        guard let duration else { return nil }
        let seconds = max(0, Int(duration.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds) }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func finishScanDuration() {
        if let scanStartedAt {
            let duration = Date.now.timeIntervalSince(scanStartedAt)
            lastScanDuration = duration
            if lastScanWasIncremental == false {
                previousFullScanDuration = duration
                UserDefaults.standard.set(duration, forKey: Self.lastFullScanDurationKey)
            }
        }
        scanStartedAt = nil
    }

    private func refreshDiskUsage() { objectWillChange.send() }

    private func saveSnapshotsInBackground(_ snapshotsToSave: [Snapshot], checkpoint: ScanCheckpoint? = nil) {
        Task.detached(priority: .utility) { [weak self] in
            do {
                // See optimizeHistory: do not share a SQLite connection across
                // the main actor and a detached task.
                let backgroundStore = SnapshotStore()
                let storedBytes = try backgroundStore.save(snapshotsToSave)
                if let checkpoint { try backgroundStore.saveCheckpoint(checkpoint) }
                await self?.applyStoredBytes(storedBytes)
                if let checkpoint { await self?.commitCheckpoint(checkpoint) }
            } catch {
                await self?.reportSnapshotSaveError(error)
            }
        }
    }

    private func reportSnapshotSaveError(_ error: Error) {
        errorMessage = "Не удалось сохранить историю: \(error.localizedDescription)"
    }

    private func commitCheckpoint(_ checkpoint: ScanCheckpoint) {
        changeTracker.commit(checkpoint.eventID)
    }

    private func applyStoredBytes(_ storedBytes: [UUID: Int]) {
        snapshots = snapshots.map { snapshot in
            guard let bytes = storedBytes[snapshot.id] else { return snapshot }
            return snapshot.withStorageBytes(bytes)
        }
    }

    /// Converts fine-grained FSEvents paths into the smallest safe set of
    /// folders to rescan. A root-level event or too many affected branches
    /// intentionally falls back to a complete scan.
    nonisolated private static func incrementalRoots(
        for changedPaths: [String],
        root: URL
    ) -> [URL]? {
        let rootPath = root.standardizedFileURL.path
        var candidates = Set<String>()
        let manager = FileManager.default

        for changedPath in changedPaths {
            let eventURL = URL(fileURLWithPath: changedPath).standardizedFileURL
            var candidate = eventURL
            var isDirectory: ObjCBool = false
            if !manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                candidate.deleteLastPathComponent()
            }
            let path = candidate.path
            guard path != rootPath else { return nil }
            guard path.hasPrefix(rootPath + "/"), path != "/Volumes", path != "/System/Volumes" else { continue }
            candidates.insert(path)
        }

        let ordered = candidates.sorted {
            $0.split(separator: "/").count < $1.split(separator: "/").count
        }
        var roots: [String] = []
        for path in ordered where !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            roots.append(path)
        }
        guard roots.count <= 24 else { return nil }
        return roots.map(URL.init(fileURLWithPath:))
    }

    nonisolated private static func refreshChangedFolders(
        _ roots: [URL],
        previousSizes: [String: Int64],
        previousEntryCount: Int?,
        progress: @escaping @Sendable (_ completed: Int, _ estimatedTotal: Int?) async -> Void
    ) async throws -> FolderScanner.Result {
        var mergedSizes = previousSizes
        var refreshedEntries = 0

        for root in roots {
            try Task.checkCancellation()
            let completedBeforeRoot = refreshedEntries
            let oldSize = mergedSizes[root.path, default: 0]
            let result = try await FolderScanner.scan(
                root: root,
                estimatedEntryCount: nil,
                progress: { completed, _ in await progress(completedBeforeRoot + completed, nil) }
            )
            let rootPath = root.path
            let descendantPrefix = rootPath + "/"
            mergedSizes = mergedSizes.filter { $0.key != rootPath && !$0.key.hasPrefix(descendantPrefix) }
            for (path, bytes) in result.folderBytes { mergedSizes[path] = bytes }

            let delta = result.folderBytes[rootPath, default: 0] - oldSize
            var parent = root.deletingLastPathComponent()
            while parent.path != rootPath {
                if mergedSizes[parent.path] != nil { mergedSizes[parent.path, default: 0] += delta }
                let next = parent.deletingLastPathComponent()
                if next.path == parent.path { break }
                parent = next
            }
            refreshedEntries += result.entryCount
        }
        await progress(refreshedEntries, nil)
        // Folder sizes are exact. The previous total entry count remains the
        // best progress estimate until per-folder entry counts are introduced.
        return FolderScanner.Result(folderBytes: mergedSizes, entryCount: previousEntryCount ?? refreshedEntries)
    }

    private func finishHistoryOptimization(error: Error? = nil) {
        isOptimizingHistory = false
        if let error {
            errorMessage = "Не удалось оптимизировать историю: \(error.localizedDescription)"
        }
    }
}
