import Foundation

enum FolderScanner {
    struct Result {
        let folderBytes: [String: Int64]
        let entryCount: Int
    }

    /// Returns allocated logical sizes for every folder below `root`, including root itself.
    static func scan(
        root: URL,
        estimatedEntryCount: Int?,
        progress: @escaping @Sendable (_ completed: Int, _ estimatedTotal: Int?) async -> Void
    ) async throws -> Result {
        let manager = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var bytes: [String: Int64] = [rootPath: 0]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else {
            throw CocoaError(.fileNoSuchFile)
        }

        var completed = 0

        for case let item as URL in enumerator {
            try Task.checkCancellation()
            completed += 1
            if completed.isMultiple(of: 250) {
                await progress(completed, estimatedEntryCount)
            }
            let url = item.standardizedFileURL
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            let path = url.path
            // Mounted external disks and APFS's internal Data-volume mount would
            // otherwise be counted as part of / (and Data would be double-counted).
            if path == "/Volumes" || path == "/System/Volumes" {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                bytes[path, default: 0] += 0
                continue
            }
            guard values.isRegularFile == true else { continue }
            let fileSize = Int64(values.fileSize ?? 0)
            let parent = url.deletingLastPathComponent().path
            bytes[parent, default: 0] += fileSize
        }
        // Files add only to their direct parent during enumeration. Afterwards,
        // aggregate child folders into parents once, avoiding O(depth) work per file.
        let paths = bytes.keys.sorted {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }
        for path in paths where path != rootPath {
            try Task.checkCancellation()
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if bytes[parent] != nil { bytes[parent, default: 0] += bytes[path, default: 0] }
        }
        await progress(completed, estimatedEntryCount)
        return Result(folderBytes: bytes, entryCount: completed)
    }

    private static func shouldSkip(_ path: String) -> Bool {
        path == "/Volumes" || path == "/System/Volumes"
    }
}
