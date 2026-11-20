import Darwin
import Foundation
import Testing
@testable import ToolboxCore
@testable import HanvonToolbox

struct SyncBackupManagementTests {
    @Test func exportsVerifiedOldContentAndPreservesExistingFiles() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanUp() }
        let backup = try await fixture.makeBackup()
        let exported = fixture.directory.appending(path: "export.txt")
        try await fixture.store.exportPrevious(backup.id, to: exported)
        #expect(try Data(contentsOf: exported) == Data("old".utf8))
        await #expect(throws: CocoaError.self) {
            try await fixture.store.exportPrevious(backup.id, to: exported)
        }
        #expect(try Data(contentsOf: exported) == Data("old".utf8))
        let sizes = try await fixture.store.storedFileBytes(for: [backup])
        #expect(try #require(sizes[backup.id]) > 14)

        let files = try await fixture.store.files(backup.id)
        try Data("tampered".utf8).write(to: files.previous)
        let failed = fixture.directory.appending(path: "failed.txt")
        await #expect(throws: ToolboxError.self) {
            try await fixture.store.exportPrevious(backup.id, to: failed)
        }
        #expect(!FileManager.default.fileExists(atPath: failed.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .allSatisfy { !$0.hasPrefix(".hanvon-export-") })
    }

    @Test func cleanupProtectsIncompleteUpdatesAndRestoreDependencies() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanUp() }
        let original = try await fixture.makeBackup()
        await #expect(throws: ToolboxError.self) {
            try await fixture.store.trashCompleted(original.id, protectedIDs: [original.id])
        }
        var pending = original
        pending.completed = false
        try await fixture.store.save(pending)
        await #expect(throws: ToolboxError.self) {
            try await fixture.store.trashCompleted(original.id, protectedIDs: [])
        }
        try await fixture.store.save(original)
        let request = SyncUpdate(path: original.update.path, direction: original.update.direction,
                                 source: original.update.destination, destination: original.update.source,
                                 restoringBackup: original.id)
        let restore = SyncBackup(id: UUID(), createdAt: Date(), scope: original.scope, update: request, completed: false)
        try await fixture.store.save(restore)
        await #expect(throws: ToolboxError.self) {
            try await fixture.store.trashCompleted(original.id, protectedIDs: [])
        }
        #expect(try await fixture.store.record(original.id)?.completed == true)
        let files = try await fixture.store.files(original.id)
        #expect(try Data(contentsOf: files.previous) == Data("old".utf8))
    }

    @Test func pendingTransferRowsProtectTheirOwnAndReferencedBackups() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanUp() }
        let backup = try await fixture.makeBackup()
        let restore = SyncUpdate(path: backup.update.path, direction: backup.update.direction,
                                 source: backup.update.destination, destination: backup.update.source,
                                 restoringBackup: backup.id)
        let waiting = TransferStep(name: "waiting", action: .syncUpdate(restore))
        let running = TransferStep(name: "running", action: .syncUpdate(backup.update))
        let completed = TransferStep(name: "completed", action: .syncUpdate(backup.update))
        let target = TransferDestination(connection: .companion, identity: "reader", root: .companion(path: ""),
                                         volumeName: "共享", volumeIdentity: "root", launchID: nil)
        let batch = TransferRecord(title: "恢复", target: target, remotePath: [], localFolder: nil, rows: [
            .init(step: waiting), .init(step: running, result: .running), .init(step: completed, result: .succeeded),
        ])
        #expect(batch.requiredBackupIDs == [waiting.id, running.id, backup.id])

        let lock = try await fixture.store.lock(scope: backup.scope, update: backup.update)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        await #expect(throws: ToolboxError.self) {
            try await fixture.store.exportPrevious(backup.id, to: fixture.directory.appending(path: "locked.txt"))
        }
        await #expect(throws: ToolboxError.self) {
            try await fixture.store.trashCompleted(backup.id, protectedIDs: [])
        }
    }

    @Test func migratesDeviceCopyFromCompletedTransferAfterLocalBackupWasCleared() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanUp() }
        let old = try await fixture.makeBackup()
        let files = try await fixture.store.files(old.id)
        try FileManager.default.removeItem(at: files.source.deletingLastPathComponent())
        try FileManager.default.removeItem(at: fixture.directory.appending(path: "backups/RecoveryCopies"))
        #expect(try await fixture.store.deviceCopies().isEmpty)

        let migrated = try await fixture.store.deviceCopies(including: [old])
        #expect(migrated.map(\.id) == [old.id])
        #expect(migrated.first?.update.destination == old.update.destination)
        #expect(try await fixture.store.deviceCopies().map(\.id) == [old.id])
    }
}

private struct BackupFixture {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    var store: SyncBackupStore { SyncBackupStore(directory: directory.appending(path: "backups")) }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func makeBackup() async throws -> SyncBackup {
        let id = UUID()
        let store = store
        let files = try await store.files(id)
        try Data("old".utf8).write(to: files.previous)
        try Data("new version".utf8).write(to: files.source)
        let update = SyncUpdate(path: ["book.txt"], direction: .toDevice,
                                source: try DirectorySync.fingerprint(of: files.source),
                                destination: try DirectorySync.fingerprint(of: files.previous))
        let scope = SyncBackupScope(device: Data("reader".utf8), local: try .init(directory), remotePath: [])
        let record = SyncBackup(id: id, createdAt: Date(), scope: scope, update: update, completed: true)
        try await store.save(record)
        return record
    }
}
