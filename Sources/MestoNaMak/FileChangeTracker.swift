import Foundation
import CoreServices

struct ScanCheckpoint: Codable {
    let rootPath: String
    let eventID: UInt64
}

struct IncrementalScanPlan {
    let changedPaths: [String]
    let eventID: UInt64
}

/// Uses macOS's persistent FSEvents journal. It deliberately asks for a full
/// scan whenever the journal reports that events might have been lost.
final class FileChangeTracker {
    private let rootPath: String
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var checkpoint: UInt64?
    private var newestEventID: UInt64 = 0
    /// The event ID is retained per path so a completed scan never discards
    /// changes that happened while that scan was still running.
    private var changedPaths: [String: UInt64] = [:]
    private var historyReady = false
    private var requiresFullScan = false
    private var unsafeEventID: UInt64?

    init(rootURL: URL, checkpoint: ScanCheckpoint?) {
        rootPath = rootURL.standardizedFileURL.path
        if checkpoint?.rootPath == rootPath { self.checkpoint = checkpoint?.eventID }
        start()
    }

    deinit { stop() }

    func plan() -> IncrementalScanPlan? {
        lock.lock(); defer { lock.unlock() }
        guard historyReady, !requiresFullScan, let checkpoint else { return nil }
        return IncrementalScanPlan(changedPaths: Array(changedPaths.keys), eventID: max(checkpoint, newestEventID))
    }

    /// After app launch FSEvents needs a brief moment to replay changes since
    /// the saved checkpoint. Without this wait, an immediate click on Scan
    /// unnecessarily falls back to a full disk walk.
    func waitForHistory(maximumWait: Int = 20) async {
        guard needsHistoryReplay else { return }
        for _ in 0..<maximumWait {
            if historyReplayFinished { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private var needsHistoryReplay: Bool {
        lock.lock(); defer { lock.unlock() }
        return checkpoint != nil && !historyReady && !requiresFullScan
    }

    private var historyReplayFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return historyReady || requiresFullScan
    }

    func fullScanCheckpoint() -> ScanCheckpoint {
        ScanCheckpoint(rootPath: rootPath, eventID: UInt64(FSEventsGetCurrentEventId()))
    }

    func commit(_ eventID: UInt64) {
        lock.lock(); defer { lock.unlock() }
        checkpoint = eventID
        changedPaths = changedPaths.filter { $0.value > eventID }
        if let unsafeEventID, unsafeEventID <= eventID { self.unsafeEventID = nil }
        requiresFullScan = unsafeEventID != nil
        historyReady = true
    }

    private func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let since = checkpoint ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        // The callback reads event paths as a CFArray/NSArray, so explicitly
        // request Core Foundation types instead of the default C string array.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes
        )
        stream = FSEventStreamCreate(nil, fileEventsCallback, &context, [rootPath] as CFArray, since, 0.2, flags)
        guard let stream else { requiresFullScan = true; return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "DiskPulse.FSEvents"))
        if !FSEventStreamStart(stream) { requiresFullScan = true }
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func receive(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>) {
        // FSEvents passes an unmanaged CFArray of paths. Bridging it via
        // `unsafeBitCast` can trap on newer Swift runtimes before the window
        // is created; use the Core Foundation ownership convention instead.
        let values = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        lock.lock(); defer { lock.unlock() }
        for index in 0..<min(count, values.count) {
            let flag = flags[index]
            newestEventID = max(newestEventID, UInt64(ids[index]))
            if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { historyReady = true }
            // MustScanSubDirs is still safe for an incremental scan: macOS
            // gives us the affected directory and we rescan that whole branch.
            // Only dropped events, a changed root, or wrapped IDs make the
            // journal unreliable for the disk as a whole.
            let unsafe = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
            if flag & unsafe != 0 {
                requiresFullScan = true
                unsafeEventID = max(unsafeEventID ?? 0, UInt64(ids[index]))
            }
            if let path = values[safe: index], path.hasPrefix(rootPath) {
                changedPaths[path] = UInt64(ids[index])
            }
        }
    }
}

private let fileEventsCallback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
    guard let info else { return }
    Unmanaged<FileChangeTracker>.fromOpaque(info).takeUnretainedValue().receive(count: count, paths: paths, flags: flags, ids: ids)
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
