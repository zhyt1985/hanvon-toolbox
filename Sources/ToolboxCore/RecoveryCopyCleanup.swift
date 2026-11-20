import Foundation

public struct RecoveryCopyCleanup: Sendable {
    public let backupID: UUID
    public let originalName: String
    public let expected: DirectorySync.Fingerprint

    public init(backupID: UUID, originalName: String, expected: DirectorySync.Fingerprint) throws {
        try validateFileName(originalName)
        guard !SyncBackup.isWorkingFile(originalName), expected.sha256.count == 32 else {
            throw ToolboxError.message("恢复副本记录无效。")
        }
        self.backupID = backupID
        self.originalName = originalName
        self.expected = expected
    }

    var retainedName: String { ".HanvonToolbox-update-\(backupID.uuidString).old" }
    var stageName: String { ".HanvonToolbox-update-\(backupID.uuidString).new" }
}

public extension DeviceConnection {
    func cleanupRecoveryCopy(in folder: DeviceFolder, request: RecoveryCopyCleanup) async throws -> Bool {
        guard kind == .usb else { throw ToolboxError.unsupported("请更新伴侣应用以清理设备恢复副本。") }
        let entries = try await list(folder)
        guard let copy = try recoveryItem(request.retainedName, in: entries) else { return false }
        try validateRecoveryContext(entries, request: request)
        guard !copy.isFolder, copy.size == request.expected.byteCount else {
            throw ToolboxError.message("设备恢复副本的类型或大小已改变。")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("recovery")
        try await download(copy, to: file, progress: nil)
        guard try DirectorySync.fingerprint(of: file) == request.expected else {
            throw ToolboxError.message("设备恢复副本内容已改变，清理已停止。")
        }
        let fresh = try await list(folder)
        try validateRecoveryContext(fresh, request: request)
        guard let current = try recoveryItem(request.retainedName, in: fresh),
              current.id == copy.id, !current.isFolder, current.size == request.expected.byteCount else {
            throw ToolboxError.message("设备恢复副本在清理前发生变化。")
        }
        try Task.checkCancellation()
        try await delete(current)
        guard try recoveryItem(request.retainedName, in: await list(folder)) == nil else {
            throw ToolboxError.message("设备恢复副本尚未删除，可重试清理。")
        }
        return true
    }
}

private func recoveryItem(_ name: String, in entries: [DeviceItem]) throws -> DeviceItem? {
    let matches = entries.filter { DirectorySync.nameKey($0.name) == DirectorySync.nameKey(name) }
    guard matches.count <= 1, matches.first.map({ $0.name == name }) != false else {
        throw ToolboxError.message("设备目录含有同名或大小写相近的项目。")
    }
    return matches.first
}

private func validateRecoveryContext(_ entries: [DeviceItem], request: RecoveryCopyCleanup) throws {
    guard let original = try recoveryItem(request.originalName, in: entries), !original.isFolder else {
        throw ToolboxError.message("当前文件已不存在，保留设备恢复副本。")
    }
    guard try recoveryItem(request.stageName, in: entries) == nil else {
        throw ToolboxError.message("设备上仍有未完成的更新，请先处理传输记录。")
    }
}
