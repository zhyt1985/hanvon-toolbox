import Foundation

public struct SyncUpdate: Codable, Equatable, Sendable {
    public let path: [String]
    public let direction: DirectorySync.Direction
    public let source: DirectorySync.Fingerprint
    public let destination: DirectorySync.Fingerprint
    public let restoringBackup: UUID?

    public init(path: [String], direction: DirectorySync.Direction, source: DirectorySync.Fingerprint,
                destination: DirectorySync.Fingerprint, restoringBackup: UUID? = nil) {
        self.path = path
        self.direction = direction
        self.source = source
        self.destination = destination
        self.restoringBackup = restoringBackup
    }
}

public struct SyncBackupScope: Codable, Equatable, Sendable {
    public let device: Data
    public let local: DirectorySync.LocalRoot
    public let remotePath: [String]

    public init(device: Data, local: DirectorySync.LocalRoot, remotePath: [String]) {
        self.device = device
        self.local = local
        self.remotePath = remotePath
    }
}

public struct SyncBackup: Codable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let scope: SyncBackupScope
    public let update: SyncUpdate
    public var completed: Bool
    public var deviceCopyCleaned: Bool?

    public init(id: UUID, createdAt: Date, scope: SyncBackupScope, update: SyncUpdate, completed: Bool,
                deviceCopyCleaned: Bool? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.scope = scope
        self.update = update
        self.completed = completed
        self.deviceCopyCleaned = deviceCopyCleaned
    }

    var stageName: String { ".HanvonToolbox-update-\(id.uuidString).new" }
    var retainedName: String { ".HanvonToolbox-update-\(id.uuidString).old" }

    public static func isWorkingFile(_ name: String) -> Bool {
        let prefix = ".HanvonToolbox-update-"
        guard name.hasPrefix(prefix), name.hasSuffix(".old") || name.hasSuffix(".new") else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil
    }
}
