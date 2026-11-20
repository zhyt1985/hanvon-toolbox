import CryptoKit
import Darwin
import Foundation

public actor SyncBackupStore {
    public static let shared = SyncBackupStore()
    private let directory: URL

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "HanvonToolbox/SyncBackups")) {
        self.directory = directory
    }

    public func load() throws -> [SyncBackup] {
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        var records: [SyncBackup] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            if let record = try record(id) { records.append(record) }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    public func record(_ id: UUID) throws -> SyncBackup? {
        do {
            let data = try Data(contentsOf: folder(id).appendingPathComponent("record.json"))
            let record = try JSONDecoder().decode(SyncBackup.self, from: data)
            guard record.id == id else { throw ToolboxError.message("旧版本记录不匹配。") }
            return record
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func save(_ record: SyncBackup) throws {
        try createFolder(folder(record.id))
        try JSONEncoder().encode(record).write(to: folder(record.id).appendingPathComponent("record.json"), options: .atomic)
        try archiveDeviceCopy(record)
    }

    public func deviceCopies(including completedTransfers: [SyncBackup] = []) throws -> [SyncBackup] {
        var records: [UUID: SyncBackup] = [:]
        let receipts = directory.appendingPathComponent("RecoveryCopies")
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            files = []
        }
        for file in files where file.pathExtension == "json" {
            let record = try JSONDecoder().decode(SyncBackup.self, from: Data(contentsOf: file))
            guard file.lastPathComponent == "\(record.id.uuidString).json",
                  record.completed, record.update.direction == .toDevice else {
                throw ToolboxError.message("设备副本记录不匹配。")
            }
            records[record.id] = record
        }
        for record in try load() + completedTransfers where record.completed && record.update.direction == .toDevice {
            if records[record.id] == nil {
                try archiveDeviceCopy(record)
                records[record.id] = record
            }
        }
        return records.values.filter { $0.deviceCopyCleaned != true }.sorted { $0.createdAt > $1.createdAt }
    }

    public func cleanupDeviceCopy(_ id: UUID, scope: SyncBackupScope, protectedIDs: Set<UUID>,
                                  device: any DeviceConnection, volumeRoot: DeviceFolder) async throws -> Bool {
        guard !protectedIDs.contains(id),
              var record = try deviceCopies().first(where: { $0.id == id }), record.scope == scope else {
            throw ToolboxError.message("设备副本不可清理，请核对记录和未完成任务。")
        }
        let lock = try lock(scope: scope, update: record.update)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        let dependent = try load().contains { !$0.completed && ($0.id == id || $0.update.restoringBackup == id) }
        guard !dependent else { throw ToolboxError.message("未完成的恢复仍需要这份副本。") }
        guard let original = record.update.path.last else { throw ToolboxError.message("原文件名不可用。") }
        let executor = TransferExecutor(device: device, volumeRoot: volumeRoot, devicePath: scope.remotePath,
                                        syncRoot: scope.local)
        let parent = try await executor.deviceFolder(Array(record.update.path.dropLast()), create: false)
        let request = try RecoveryCopyCleanup(backupID: id, originalName: original, expected: record.update.destination)
        let removed = try await device.cleanupRecoveryCopy(in: parent, request: request)
        record.deviceCopyCleaned = true
        try writeDeviceReceipt(record)
        return removed
    }

    public func files(_ id: UUID) throws -> (source: URL, previous: URL) {
        let base = folder(id)
        try createFolder(base)
        return (base.appendingPathComponent("source"), base.appendingPathComponent("previous"))
    }

    public func stagingFile(_ record: SyncBackup) -> URL { folder(record.id).appendingPathComponent(record.stageName) }

    public func storedFileBytes(for records: [SyncBackup]) throws -> [UUID: UInt64] {
        var sizes: [UUID: UInt64] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        for record in records {
            let files = try FileManager.default.contentsOfDirectory(at: folder(record.id),
                                                                     includingPropertiesForKeys: Array(keys))
            var bytes: UInt64 = 0
            for file in files {
                let values = try file.resourceValues(forKeys: keys)
                if values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize {
                    bytes += UInt64(clamping: size)
                }
            }
            sizes[record.id] = bytes
        }
        return sizes
    }

    public func exportPrevious(_ id: UUID, to destination: URL) throws {
        guard let record = try record(id), destination.isFileURL else {
            throw ToolboxError.message("旧版本不可用。")
        }
        let lock = try lock(scope: record.scope, update: record.update)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        try Task.checkCancellation()
        let source = folder(id).appendingPathComponent("previous")
        guard try DirectorySync.fingerprint(of: source) == record.update.destination else {
            throw ToolboxError.message("旧版本内容校验失败。")
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".hanvon-export-\(UUID().uuidString)")
        try createFolder(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let copy = stage.appendingPathComponent("content")
        try FileManager.default.copyItem(at: source, to: copy)
        guard try DirectorySync.fingerprint(of: copy) == record.update.destination,
              try DirectorySync.fingerprint(of: source) == record.update.destination else {
            throw ToolboxError.message("旧版本导出校验失败。")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: copy, to: destination)
    }

    public func trashCompleted(_ id: UUID, protectedIDs: Set<UUID>) throws {
        guard !protectedIDs.contains(id), let record = try record(id), record.completed else {
            throw ToolboxError.message("未完成任务仍需要这份备份，请先处理传输记录。")
        }
        let lock = try lock(scope: record.scope, update: record.update)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        let dependent = try load().contains { !$0.completed && $0.update.restoringBackup == id }
        guard !dependent else {
            throw ToolboxError.message("未完成的恢复仍需要这份备份。")
        }
        try Task.checkCancellation()
        try archiveDeviceCopy(record)
        try FileManager.default.trashItem(at: folder(id), resultingItemURL: nil)
    }

    func lock(scope: SyncBackupScope, update: SyncUpdate) throws -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = Data()
        switch update.direction {
        case .toMac:
            data.append(try encoder.encode(scope.local))
            data.append(try encoder.encode(update.path))
        case .toDevice:
            data.append(scope.device)
            data.append(try encoder.encode(scope.remotePath + update.path))
        }
        data.append(Data(update.direction.rawValue.utf8))
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let locks = directory.appendingPathComponent("Locks")
        try createFolder(locks)
        let fd = open(locks.appendingPathComponent(key).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ToolboxError.message("无法锁定旧版本记录。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ToolboxError.message("这个文件正在更新，请等当前操作完成。")
        }
        return fd
    }

    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }

    private func archiveDeviceCopy(_ record: SyncBackup) throws {
        guard record.completed, record.update.direction == .toDevice else { return }
        let receipt = directory.appendingPathComponent("RecoveryCopies/\(record.id.uuidString).json")
        if FileManager.default.fileExists(atPath: receipt.path) {
            let existing = try JSONDecoder().decode(SyncBackup.self, from: Data(contentsOf: receipt))
            if existing.deviceCopyCleaned == true { return }
        }
        try writeDeviceReceipt(record)
    }

    private func writeDeviceReceipt(_ record: SyncBackup) throws {
        let receipts = directory.appendingPathComponent("RecoveryCopies")
        try createFolder(receipts)
        try JSONEncoder().encode(record).write(to: receipts.appendingPathComponent("\(record.id.uuidString).json"),
                                               options: .atomic)
    }

    private func createFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}
