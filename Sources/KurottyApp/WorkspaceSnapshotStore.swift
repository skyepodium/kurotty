import Foundation

struct WorkspaceSnapshotSaveReport: Equatable {
    var snapshotURL: URL
    var backupURL: URL?
}

enum WorkspaceSnapshotLoadResult: Equatable, CustomStringConvertible {
    case missingFile(URL)
    case decodeFailure(URL, String)
    case schemaMismatch(URL, expectedVersion: Int, actualVersion: Int)
    case success(WorkspaceSnapshot)

    var description: String {
        switch self {
        case let .missingFile(url):
            return "missingFile(\(url.path))"
        case let .decodeFailure(url, reason):
            return "decodeFailure(\(url.path), \(reason))"
        case let .schemaMismatch(url, expectedVersion, actualVersion):
            return "schemaMismatch(\(url.path), expected: \(expectedVersion), actual: \(actualVersion))"
        case let .success(snapshot):
            return "success(schemaVersion: \(snapshot.schemaVersion), windows: \(snapshot.windows.count))"
        }
    }
}

struct WorkspaceSnapshotStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let expectedSchemaVersion: Int

    init(
        fileManager: FileManager = .default,
        expectedSchemaVersion: Int = WorkspaceSnapshot.currentSchemaVersion
    ) {
        self.fileManager = fileManager
        self.expectedSchemaVersion = expectedSchemaVersion

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        decoder = JSONDecoder()
    }

    func save(
        _ snapshot: WorkspaceSnapshot,
        to url: URL
    ) throws -> WorkspaceSnapshotSaveReport {
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryURL = directoryURL
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let data = try encoder.encode(snapshot)
        try data.write(to: temporaryURL, options: [.withoutOverwriting])

        do {
            let backupURL: URL?
            if fileManager.fileExists(atPath: url.path) {
                let backupFileName = "\(url.lastPathComponent).backup-\(UUID().uuidString)"
                let replacementBackupURL = directoryURL.appendingPathComponent(backupFileName)
                backupURL = replacementBackupURL
                try fileManager.copyItem(at: url, to: replacementBackupURL)
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                backupURL = nil
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            return WorkspaceSnapshotSaveReport(snapshotURL: url, backupURL: backupURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    func load(from url: URL) -> WorkspaceSnapshotLoadResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missingFile(url)
        }

        do {
            let data = try Data(contentsOf: url)
            let snapshot = try decoder.decode(WorkspaceSnapshot.self, from: data)
            guard snapshot.schemaVersion == expectedSchemaVersion else {
                return .schemaMismatch(
                    url,
                    expectedVersion: expectedSchemaVersion,
                    actualVersion: snapshot.schemaVersion
                )
            }
            return .success(snapshot)
        } catch {
            return .decodeFailure(url, String(describing: error))
        }
    }
}
