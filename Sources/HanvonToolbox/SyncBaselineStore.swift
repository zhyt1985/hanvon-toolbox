import Foundation
import ToolboxCore

struct SyncBaselineStore {
    typealias Files = [String: DirectorySync.Fingerprint]
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "HanvonToolbox/SyncBaselines")) {
        self.directory = directory
    }

    func load(for presetID: UUID) throws -> Files {
        do {
            let data = try Data(contentsOf: location(of: presetID))
            return try JSONDecoder().decode(Files.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
    }

    func recordMatches(_ rows: [DirectorySync.Row], previous: Files, for presetID: UUID) throws -> Files {
        var files = previous
        for row in rows {
            if let fingerprint = row.fingerprint {
                files[row.path] = fingerprint
            }
        }
        if files != previous {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(files).write(to: location(of: presetID), options: .atomic)
        }
        return files
    }

    func remove(for presetID: UUID) throws {
        do {
            try FileManager.default.removeItem(at: location(of: presetID))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // A preset without verified files has no baseline on disk.
        }
    }

    private func location(of presetID: UUID) -> URL {
        directory.appending(path: "\(presetID.uuidString).json")
    }
}
