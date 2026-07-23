import Foundation

struct FolderSize: Identifiable, Hashable {
    let path: String
    let bytes: Int64

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent }
}

struct FolderNode: Identifiable {
    let path: String
    let bytes: Int64
    let growth: Int64
    let hasChildren: Bool

    var id: String { path }
    var name: String {
        path == "/" ? "Disk" : URL(fileURLWithPath: path).lastPathComponent
    }
}

struct Snapshot: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let rootPath: String
    let folderBytes: [String: Int64]
    let scannedEntries: Int?
    /// Size of this snapshot's compressed payload in the local history database.
    let storageBytes: Int?

    init(createdAt: Date = .now, rootPath: String, folderBytes: [String: Int64], scannedEntries: Int? = nil, storageBytes: Int? = nil) {
        self.id = UUID()
        self.createdAt = createdAt
        self.rootPath = rootPath
        self.folderBytes = folderBytes
        self.scannedEntries = scannedEntries
        self.storageBytes = storageBytes
    }

    func withStorageBytes(_ bytes: Int) -> Snapshot {
        var copy = self
        copy = Snapshot(id: id, createdAt: createdAt, rootPath: rootPath, folderBytes: folderBytes, scannedEntries: scannedEntries, storageBytes: bytes)
        return copy
    }

    private init(id: UUID, createdAt: Date, rootPath: String, folderBytes: [String: Int64], scannedEntries: Int?, storageBytes: Int?) {
        self.id = id
        self.createdAt = createdAt
        self.rootPath = rootPath
        self.folderBytes = folderBytes
        self.scannedEntries = scannedEntries
        self.storageBytes = storageBytes
    }
}

enum SortMode: CaseIterable, Identifiable {
    case size
    case growth
    var id: Self { self }
    var translationKey: String { self == .size ? "size" : "growth" }
}

enum ScanMode {
    case accelerated
    case full
}
