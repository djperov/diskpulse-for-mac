import Foundation
import Compression
import SQLite3

/// Small SQLite database; SQLite ships with macOS, so DiskPulse has no runtime dependency.
final class SnapshotStore {
    private var database: OpaquePointer?
    private let legacyJSONURLs: [URL]
    private let legacyCompressedURLs: [URL]

    init(fileManager: FileManager = .default) {
        let folder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskPulse", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let previousFolder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MestoNaMak", isDirectory: true)
        legacyJSONURLs = [folder, previousFolder].map { $0.appendingPathComponent("snapshots.json") }
        legacyCompressedURLs = [folder, previousFolder].map { $0.appendingPathComponent("snapshots.lzfse") }
        let databaseURL = folder.appendingPathComponent("history.sqlite")
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else { return }
        try? execute("""
            CREATE TABLE IF NOT EXISTS snapshots (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS snapshots_created_at ON snapshots(created_at DESC);
            CREATE TABLE IF NOT EXISTS scan_checkpoints (
                root_path TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL
            );
            """)
    }

    deinit { sqlite3_close(database) }

    func load() -> [Snapshot] {
        let snapshots = readDatabase()
        return snapshots.isEmpty ? readLegacyHistory() : snapshots
    }

    /// Replaces history transactionally. The database is only changed after every
    /// snapshot has been encoded, and legacy files are removed afterwards.
    @discardableResult
    func save(_ snapshots: [Snapshot]) throws -> [UUID: Int] {
        guard database != nil else { throw StoreError.databaseUnavailable }
        let payloads = try snapshots.map { try encode($0) }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("DELETE FROM snapshots;")
            let statement = try prepare("INSERT INTO snapshots (id, created_at, payload) VALUES (?, ?, ?);")
            defer { sqlite3_finalize(statement) }
            for (snapshot, payload) in zip(snapshots, payloads) {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, snapshot.id.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(statement, 2, snapshot.createdAt.timeIntervalSince1970)
                let bound = payload.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, 3, raw.baseAddress, Int32(payload.count), SQLITE_TRANSIENT)
                }
                guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw lastError }
            }
            try execute("COMMIT;")
            for url in legacyJSONURLs + legacyCompressedURLs { try? FileManager.default.removeItem(at: url) }
            return Dictionary(uniqueKeysWithValues: zip(snapshots, payloads).map { ($0.0.id, $0.1.count) })
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func compact() throws {
        try execute("VACUUM;")
    }

    func loadCheckpoint(rootPath: String) -> ScanCheckpoint? {
        guard let statement = try? prepare("SELECT payload FROM scan_checkpoints WHERE root_path = ?;") else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, rootPath, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { return nil }
        return try? JSONDecoder().decode(ScanCheckpoint.self, from: Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    func saveCheckpoint(_ checkpoint: ScanCheckpoint) throws {
        let payload = try JSONEncoder().encode(checkpoint)
        let statement = try prepare("INSERT OR REPLACE INTO scan_checkpoints (root_path, payload) VALUES (?, ?);")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, checkpoint.rootPath, -1, SQLITE_TRANSIENT)
        let bound = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(payload.count), SQLITE_TRANSIENT) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw lastError }
    }

    private func readDatabase() -> [Snapshot] {
        guard let statement = try? prepare("SELECT payload FROM snapshots ORDER BY created_at DESC;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var snapshots: [Snapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_blob(statement, 0) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 0))
            if let snapshot = try? decode(Data(bytes: pointer, count: length)) {
                snapshots.append(snapshot.withStorageBytes(length))
            }
        }
        return snapshots
    }

    private func readLegacyHistory() -> [Snapshot] {
        let data: Data?
        if let url = legacyCompressedURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let compressed = try? Data(contentsOf: url) {
            data = try? decompress(compressed)
        } else if let url = legacyJSONURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            data = try? Data(contentsOf: url)
        } else { data = nil }
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Snapshot].self, from: data)) ?? []
    }

    private func encode(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try compress(encoder.encode(snapshot))
    }

    private func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Snapshot.self, from: decompress(data))
    }

    private func compress(_ input: Data) throws -> Data { try transform(input, operation: COMPRESSION_STREAM_ENCODE) }
    private func decompress(_ input: Data) throws -> Data { try transform(input, operation: COMPRESSION_STREAM_DECODE) }

    private func transform(_ input: Data, operation: compression_stream_operation) throws -> Data {
        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        var stream = compression_stream(dst_ptr: destination, dst_size: 0, src_ptr: UnsafePointer(destination), src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_LZFSE) != COMPRESSION_STATUS_ERROR else { throw StoreError.codingFailed }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        let status: compression_status = try input.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { throw StoreError.codingFailed }
            stream.src_ptr = source
            stream.src_size = input.count
            var status: compression_status
            repeat {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(destination, count: bufferSize - stream.dst_size)
            } while status == COMPRESSION_STATUS_OK
            return status
        }
        guard status == COMPRESSION_STATUS_END else { throw StoreError.codingFailed }
        return output
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    private var lastError: Error {
        StoreError.database(String(cString: sqlite3_errmsg(database)))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum StoreError: LocalizedError {
    case databaseUnavailable
    case database(String)
    case codingFailed

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "SQLite database is unavailable"
        case let .database(message): return message
        case .codingFailed: return "Could not encode history"
        }
    }
}
