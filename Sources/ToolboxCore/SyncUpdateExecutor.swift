import Darwin
import Foundation

extension TransferExecutor {
    func executeUpdate(_ update: SyncUpdate, id: UUID, progress: ProgressUpdate?) async throws {
        guard let scope = backupScope, scope.local == syncRoot, scope.remotePath == devicePath,
              !update.path.isEmpty, device.kind != .wifi else {
            throw ToolboxError.message("缺少原同步目录信息，请重新生成计划。")
        }
        for name in update.path { try validateFileName(name) }
        try scope.local.validate()
        let lock = try await backups.lock(scope: scope, update: update)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        var record = try await prepareUpdate(update, id: id, scope: scope, progress: progress)
        let files = try await backups.files(id)
        try checkSnapshot(files.source, expected: update.source)
        try checkSnapshot(files.previous, expected: update.destination)
        switch update.direction {
        case .toMac:
            try updateLocal(record, source: files.source)
        case .toDevice:
            try await updateRemote(record, source: files.source, progress: progress)
        }
        record.completed = true
        try await backups.save(record)
    }

    public func updateTargetFingerprint(_ update: SyncUpdate) async throws -> DirectorySync.Fingerprint {
        let parents = Array(update.path.dropLast())
        guard let name = update.path.last, let syncRoot else {
            throw ToolboxError.message("没有指定原文件。")
        }
        try syncRoot.validate()
        switch update.direction {
        case .toMac:
            let parent = try localFolder(parents, root: syncRoot.url, create: false)
            guard try matchingLocalName(name, in: parent) != nil else {
                throw ToolboxError.message("原 Mac 文件已不存在。")
            }
            return try DirectorySync.fingerprint(of: parent.appendingPathComponent(name))
        case .toDevice:
            let parent = try await deviceFolder(parents, create: false)
            guard let item = try matchingDeviceItem(name, in: await device.list(parent)), !item.isFolder else {
                throw ToolboxError.message("原设备文件已不存在。")
            }
            return try await remoteFingerprint(item)
        }
    }

    private func prepareUpdate(_ update: SyncUpdate, id: UUID, scope: SyncBackupScope,
                               progress: ProgressUpdate?) async throws -> SyncBackup {
        if let existing = try await backups.record(id) {
            guard existing.scope == scope, existing.update == update else {
                throw ToolboxError.message("旧版本记录与本次更新不匹配。")
            }
            return existing
        }
        let files = try await backups.files(id)
        // With no journal, these are incomplete snapshots owned by this operation.
        for file in [files.source, files.previous] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        let parents = Array(update.path.dropLast())
        let name = update.path.last!
        if let backupID = update.restoringBackup {
            guard let original = try await backups.record(backupID), original.completed,
                  original.scope == scope, original.update.direction == update.direction,
                  original.update.path == update.path, original.update.destination == update.source else {
                throw ToolboxError.message("无法确认要恢复的旧版本。")
            }
            let backupFiles = try await backups.files(backupID)
            try copySnapshot(backupFiles.previous, to: files.source, expected: update.source)
        } else {
            switch update.direction {
            case .toDevice:
                let localParent = try localFolder(parents, root: scope.local.url, create: false)
                guard try matchingLocalName(name, in: localParent) != nil else {
                    throw ToolboxError.message("Mac 源文件已移动，请重新比较。")
                }
                try copySnapshot(localParent.appendingPathComponent(name), to: files.source, expected: update.source)
            case .toMac:
                let deviceParent = try await deviceFolder(parents, create: false)
                try await captureRemote(name, in: deviceParent, to: files.source, expected: update.source, progress: progress)
            }
        }
        switch update.direction {
        case .toDevice:
            let deviceParent = try await deviceFolder(parents, create: false)
            try await captureRemote(name, in: deviceParent, to: files.previous, expected: update.destination, progress: progress)
        case .toMac:
            let localParent = try localFolder(parents, root: scope.local.url, create: false)
            guard try matchingLocalName(name, in: localParent) != nil else {
                throw ToolboxError.message("Mac 目标文件已移动，请重新比较。")
            }
            try copySnapshot(localParent.appendingPathComponent(name), to: files.previous, expected: update.destination)
        }
        try scope.local.validate()
        try Task.checkCancellation()
        let record = SyncBackup(id: id, createdAt: Date(), scope: scope, update: update, completed: false)
        try await backups.save(record)
        return record
    }

    private func updateLocal(_ record: SyncBackup, source: URL) throws {
        let update = record.update
        let parent = try localFolder(Array(update.path.dropLast()), root: record.scope.local.url, create: false)
        let target = parent.appendingPathComponent(update.path.last!)
        let stage = parent.appendingPathComponent(record.stageName)
        let retained = parent.appendingPathComponent(record.retainedName)
        do {
            if try matchingLocalName(target.lastPathComponent, in: parent) != nil {
                let current = try DirectorySync.fingerprint(of: target)
                if current == update.source {
                    try? cleanLocalRetained(retained, expected: update.destination)
                    return
                }
                guard current == update.destination else {
                    throw ToolboxError.message("Mac 目标文件在预览后已改变，请重新比较。")
                }
                guard !FileManager.default.fileExists(atPath: retained.path) else {
                    throw ToolboxError.message("旧版本临时文件已存在，请核对文件状态。")
                }
            } else {
                try checkSnapshot(retained, expected: update.destination)
            }
            if FileManager.default.fileExists(atPath: stage.path) {
                let current = try DirectorySync.fingerprint(of: stage)
                if current != update.source { try FileManager.default.removeItem(at: stage) }
            }
            if !FileManager.default.fileExists(atPath: stage.path) {
                try copySnapshot(source, to: stage, expected: update.source)
            }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: target, to: retained)
                try checkSnapshot(retained, expected: update.destination)
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: stage, to: target)
            try checkSnapshot(target, expected: update.source)
            try? cleanLocalRetained(retained, expected: update.destination)
        } catch {
            if !FileManager.default.fileExists(atPath: target.path),
               FileManager.default.fileExists(atPath: retained.path) {
                try? FileManager.default.moveItem(at: retained, to: target)
            }
            throw error
        }
    }

    private func updateRemote(_ record: SyncBackup, source: URL, progress: ProgressUpdate?) async throws {
        let update = record.update
        let parent = try await deviceFolder(Array(update.path.dropLast()), create: false)
        let name = update.path.last!
        do {
            let entries = try await device.list(parent)
            if let target = try matchingDeviceItem(name, in: entries) {
                let current = try await remoteFingerprint(target)
                if current == update.source { return }
                guard current == update.destination else {
                    throw ToolboxError.message("设备目标文件在预览后已改变，请重新比较。")
                }
                guard try matchingDeviceItem(record.retainedName, in: entries) == nil else {
                    throw ToolboxError.message("设备旧版本临时文件已存在，请核对文件状态。")
                }
            } else {
                guard let old = try matchingDeviceItem(record.retainedName, in: entries),
                      try await remoteFingerprint(old) == update.destination else {
                    throw ToolboxError.message("设备原文件已移动，请先核对文件状态。")
                }
            }
            var stage = try matchingDeviceItem(record.stageName, in: entries)
            if stage == nil {
                let upload = await backups.stagingFile(record)
                if !FileManager.default.fileExists(atPath: upload.path) {
                    try copySnapshot(source, to: upload, expected: update.source)
                }
                try checkSnapshot(upload, expected: update.source)
                try await device.upload(upload, to: parent, progress: progress)
                stage = try matchingDeviceItem(record.stageName, in: await device.list(parent))
            }
            guard let stage, !stage.isFolder, try await remoteFingerprint(stage) == update.source else {
                throw ToolboxError.message("设备临时文件校验失败，旧版本已保留。")
            }
            try Task.checkCancellation()
            if let target = try matchingDeviceItem(name, in: await device.list(parent)) {
                try await device.rename(target, in: parent, to: record.retainedName)
                guard let retained = try matchingDeviceItem(record.retainedName, in: await device.list(parent)),
                      try await remoteFingerprint(retained) == update.destination else {
                    throw ToolboxError.message("设备原文件在更新时发生变化，请重新比较。")
                }
            }
            try Task.checkCancellation()
            try await device.rename(stage, in: parent, to: name)
            guard let target = try matchingDeviceItem(name, in: await device.list(parent)),
                  try await remoteFingerprint(target) == update.source else {
                throw ToolboxError.message("设备更新后校验失败，旧版本已保留。")
            }
        } catch {
            // A lost response may mean publishing succeeded. Restore only into an empty name.
            if let entries = try? await device.list(parent),
               (try? matchingDeviceItem(name, in: entries)) == nil,
               let retained = try? matchingDeviceItem(record.retainedName, in: entries) {
                try? await device.rename(retained, in: parent, to: name)
            }
            throw error
        }
    }

    private func captureRemote(_ name: String, in parent: DeviceFolder, to destination: URL,
                               expected: DirectorySync.Fingerprint, progress: ProgressUpdate?) async throws {
        guard let item = try matchingDeviceItem(name, in: await device.list(parent)), !item.isFolder else {
            throw ToolboxError.message("设备文件已移动，请重新比较。")
        }
        try await device.download(item, to: destination, progress: progress)
        try checkSnapshot(destination, expected: expected)
    }

    private func remoteFingerprint(_ item: DeviceItem) async throws -> DirectorySync.Fingerprint {
        guard !item.isFolder else { throw ToolboxError.message("目标已变成文件夹，请重新比较。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("file")
        try await device.download(item, to: copy, progress: nil)
        return try DirectorySync.fingerprint(of: copy)
    }

    private func copySnapshot(_ source: URL, to destination: URL, expected: DirectorySync.Fingerprint) throws {
        try checkSnapshot(source, expected: expected)
        try FileManager.default.copyItem(at: source, to: destination)
        try checkSnapshot(destination, expected: expected)
        try checkSnapshot(source, expected: expected)
    }

    private func checkSnapshot(_ file: URL, expected: DirectorySync.Fingerprint) throws {
        guard try DirectorySync.fingerprint(of: file) == expected else {
            throw ToolboxError.message("文件内容与计划不符，请重新比较。")
        }
    }

    private func cleanLocalRetained(_ file: URL, expected: DirectorySync.Fingerprint) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try checkSnapshot(file, expected: expected)
            try FileManager.default.removeItem(at: file)
        }
    }
}
