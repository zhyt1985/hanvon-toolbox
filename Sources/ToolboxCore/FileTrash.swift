import Foundation

public struct DeviceTrashRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let scope: Data
    public let parents: [String]
    public let name: String
    public let directory: Bool
    public let bytes: UInt64?
    public var restoreName: String?
}

public actor DeviceTrashStore {
    public static let shared = DeviceTrashStore()
    public static let folderName = ".HanvonToolbox-Trash"
    private let directory: URL
    private var working = Set<UUID>()

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "HanvonToolbox/DeviceTrash")) {
        self.directory = directory
    }

    public func load(scope: Data? = nil) throws -> [DeviceTrashRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                let record = try JSONDecoder().decode(DeviceTrashRecord.self, from: Data(contentsOf: $0))
                guard $0.lastPathComponent == record.id.uuidString + ".json" else {
                    throw ToolboxError.message("回收站记录不匹配")
                }
                return record
            }.filter { scope == nil || $0.scope == scope }.sorted { $0.date > $1.date }
    }

    public func put(_ item: DeviceItem, parents: [String], scope: Data,
                    on device: any DeviceConnection, root: DeviceFolder) async throws {
        guard !parents.contains(Self.folderName), item.name != Self.folderName,
              !SyncBackup.isWorkingFile(item.name) else { throw ToolboxError.message("不能回收工具箱工作目录") }
        let source = try await folder(parents, on: device, root: root, create: false)
        guard let fresh = try unique(item.name, in: await device.list(source)), fresh.id == item.id else {
            throw ToolboxError.message("项目已改变，请刷新后重试")
        }
        let record = DeviceTrashRecord(id: UUID(), date: Date(), scope: scope, parents: parents,
                                       name: item.name, directory: item.isFolder, bytes: item.size)
        try save(record)
        // Save before moving: a lost move response leaves a recoverable receipt.
        let target = try await folder([Self.folderName, record.id.uuidString], on: device, root: root, create: true)
        try await device.relocate(fresh, to: target, copying: false)
        guard let moved = try unique(item.name, in: await device.list(target)), matches(moved, record) else {
            throw ToolboxError.message("回收结果尚未确认，可在回收站重试恢复")
        }
    }

    public func restore(_ id: UUID, scope: Data, on device: any DeviceConnection, root: DeviceFolder) async throws -> String {
        guard !working.contains(id), var record = try load(scope: scope).first(where: { $0.id == id }) else {
            throw ToolboxError.message("回收站记录不可用")
        }
        working.insert(id); defer { working.remove(id) }
        let bucket = try await folder([Self.folderName, id.uuidString], on: device, root: root, create: false)
        let destination = try await folder(record.parents, on: device, root: root, create: false)
        let contents = try await device.list(bucket)
        let entries = try await device.list(destination)
        if contents.isEmpty, let name = record.restoreName,
           let restored = try unique(name, in: entries), matches(restored, record) {
            try remove(id); return name
        }
        guard contents.count == 1, let item = contents.first, matches(item, record),
              item.name == record.name || item.name == record.restoreName else {
            throw ToolboxError.message("回收副本不完整或尚未移入，请核对原目录")
        }
        let chosen = availableRestoredName(record.restoreName ?? record.name, occupied: entries.map(\.name))
        record.restoreName = chosen
        try save(record)
        if item.name != chosen { try await device.rename(item, in: bucket, to: chosen) }
        guard let renamed = try unique(chosen, in: await device.list(bucket)) else {
            throw ToolboxError.message("回收副本重命名未完成")
        }
        try await device.relocate(renamed, to: destination, copying: false)
        guard let restored = try unique(chosen, in: await device.list(destination)), matches(restored, record) else {
            throw ToolboxError.message("恢复结果尚未确认，请重试")
        }
        try remove(id)
        // Remove only our now-empty bucket. Keep the shared trash root for other records.
        if let trash = try? await folder([Self.folderName], on: device, root: root, create: false),
           let empty = try? unique(id.uuidString, in: await device.list(trash)), let folder = empty.folder,
           (try? await device.list(folder).isEmpty) == true { try? await device.delete(empty) }
        return chosen
    }

    public func purge(_ id: UUID, scope: Data, on device: any DeviceConnection, root: DeviceFolder) async throws {
        guard !working.contains(id), let record = try load(scope: scope).first(where: { $0.id == id }) else {
            throw ToolboxError.message("回收站记录不可用")
        }
        working.insert(id); defer { working.remove(id) }
        let trash = try await folder([Self.folderName], on: device, root: root, create: false)
        if let item = try unique(id.uuidString, in: await device.list(trash)) {
            guard let bucket = item.folder else { throw ToolboxError.message("回收目录已改变") }
            let entries = try await device.list(bucket)
            guard entries.isEmpty || (entries.count == 1 && matches(entries[0], record)
                && (entries[0].name == record.name || entries[0].name == record.restoreName)) else {
                throw ToolboxError.message("回收目录内容已改变，停止清理")
            }
            try await device.delete(item)
        }
        try remove(id)
    }

    private func matches(_ item: DeviceItem, _ record: DeviceTrashRecord) -> Bool {
        item.isFolder == record.directory && (record.directory || record.bytes == nil || item.size == record.bytes)
    }
    private func save(_ record: DeviceTrashRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: directory.appending(path: record.id.uuidString + ".json"), options: .atomic)
    }
    private func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: directory.appending(path: id.uuidString + ".json")) }
    private func unique(_ name: String, in items: [DeviceItem]) throws -> DeviceItem? {
        let matches = items.filter { DirectorySync.nameKey($0.name) == DirectorySync.nameKey(name) }
        guard matches.count <= 1, matches.first.map({ $0.name == name }) != false else {
            throw ToolboxError.message("目录有大小写相近的重名项目")
        }
        return matches.first
    }
    private func folder(_ path: [String], on device: any DeviceConnection, root: DeviceFolder, create: Bool) async throws -> DeviceFolder {
        var current = root
        for name in path {
            try validateFileName(name)
            if let item = try unique(name, in: await device.list(current)) {
                guard let child = item.folder else { throw ToolboxError.message("原目录已被同名文件替换") }
                current = child
            } else if create {
                guard let child = try await device.makeFolder(named: name, in: current).folder else { throw ToolboxError.message("无法创建回收目录") }
                current = child
            } else { throw ToolboxError.message("原目录已不存在，回收副本仍保留") }
        }
        return current
    }
}

public func availableRestoredName(_ name: String, occupied: [String]) -> String {
    let keys = Set(occupied.map(DirectorySync.nameKey))
    guard keys.contains(DirectorySync.nameKey(name)) else { return name }
    let ext = (name as NSString).pathExtension
    let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    for index in 1...100000 {
        let suffix = "（恢复副本 \(index)）"
        var ending = ext.isEmpty ? "" : "." + ext
        if (suffix + ending).utf8.count > 240 || (suffix + ending).utf16.count > 240 { ending = "" }
        var prefix = stem
        while (prefix + suffix + ending).utf8.count > 255 || (prefix + suffix + ending).utf16.count > 254 {
            prefix.removeLast()
        }
        let candidate = prefix + suffix + ending
        if !keys.contains(DirectorySync.nameKey(candidate)) { return candidate }
    }
    return UUID().uuidString
}

public struct LocalTrashRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let original: URL
    public var name: String { original.lastPathComponent }
}

public actor LocalTrashStore {
    public static let shared = LocalTrashStore()
    private let directory: URL
    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "HanvonToolbox/LocalTrash")) { self.directory = directory }
    public func load() throws -> [LocalTrashRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: "payload").path)) != nil else { return nil }
            let record = try JSONDecoder().decode(LocalTrashRecord.self, from: Data(contentsOf: folder.appending(path: "record.json")))
            guard record.id.uuidString == folder.lastPathComponent else { throw ToolboxError.message("Mac 回收记录不匹配") }
            return record
        }.sorted { $0.date > $1.date }
    }
    public func put(_ file: URL) throws {
        guard file.isFileURL, file.path != "/", !file.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw ToolboxError.message("不能回收此位置")
        }
        let record = LocalTrashRecord(id: UUID(), date: Date(), original: file)
        let folder = directory.appending(path: record.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: folder.appending(path: "record.json"), options: .atomic)
        try FileManager.default.moveItem(at: file, to: folder.appending(path: "payload"))
    }
    public func restore(_ id: UUID) throws -> URL {
        guard let record = try load().first(where: { $0.id == id }) else { throw ToolboxError.message("Mac 回收副本不存在") }
        let parent = record.original.deletingLastPathComponent()
        let name = availableRestoredName(record.name, occupied: try FileManager.default.contentsOfDirectory(atPath: parent.path))
        let destination = parent.appendingPathComponent(name)
        let folder = directory.appending(path: id.uuidString)
        try FileManager.default.moveItem(at: folder.appending(path: "payload"), to: destination)
        try? FileManager.default.removeItem(at: folder)
        return destination
    }
    public func purge(_ id: UUID) throws {
        guard try load().contains(where: { $0.id == id }) else { throw ToolboxError.message("Mac 回收副本不存在") }
        try FileManager.default.removeItem(at: directory.appending(path: id.uuidString))
    }
}
