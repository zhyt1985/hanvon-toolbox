import CryptoKit
import Foundation

public enum ContentReader {
    public static func folder(_ path: [String], from root: DeviceFolder, device: any DeviceConnection) async throws -> DeviceFolder {
        var current = root
        for name in path {
            let item = try await entry(name, in: current, device: device)
            guard let next = item.folder else { throw ToolboxError.message("来源目录已经改变") }
            current = next
        }
        return current
    }

    public static func entry(_ name: String, in folder: DeviceFolder, device: any DeviceConnection) async throws -> DeviceItem {
        try validateComponent(name)
        let matches = try await device.list(folder).filter { DirectorySync.nameKey($0.name) == DirectorySync.nameKey(name) }
        guard matches.count == 1, let match = matches.first, match.name == name else {
            throw ToolboxError.message("来源项目不存在、已改名或有重名冲突")
        }
        return match
    }

    public static func validateComponent(_ name: String) throws {
        try validateFileName(name)
        guard name.utf8.count <= 255, !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ToolboxError.message("来源包含无法安全导出的文件名")
        }
    }

    public static func scan(_ source: ContentSource, root: DeviceFolder, device: any DeviceConnection) async throws -> ContentCatalog {
        let directory = try await folder(source.path, from: root, device: device)
        if source.kind == .files {
            let entries = try await device.list(directory)
            guard entries.count <= 20_000 else { throw ToolboxError.unsupported("当前来源超过 20,000 项，请缩小范围") }
            let items = try entries.filter { !$0.name.hasPrefix(".") }.map { item in
                try validateComponent(item.name)
                return ExportContentItem(id: item.name, title: item.name, path: [item.name], isDirectory: item.isFolder,
                                         byteCount: item.size, modified: item.modified)
            }
            return .init(source: source, items: items, warnings: ["文件收集保留来源文件，不将其自动识别为书信或正式录音。"])
        }
        let index = try await noteIndex(in: directory, device: device)
        defer { try? FileManager.default.removeItem(at: index.directory) }
        let records = try await Task.detached { try HanvonNoteCatalog.read(index.file) }.value
        let entries = try await device.list(directory)
        var items: [ExportContentItem] = []
        var warnings = ["笔记与便签的类型对应关系尚未验证；本列表不区分二者。",
                        "原始目录副本不包含尚未识别的跨目录底纹、附件或资源，不承诺可回写恢复。"]
        for record in records {
            let matches = entries.filter { $0.name == record.key && $0.isFolder }
            if let item = matches.first, matches.count == 1 {
                items.append(.init(id: record.key, title: record.title, path: [record.key], isDirectory: true,
                                   modified: item.modified, noteType: record.type, protected: record.protected, indexed: true))
            } else { warnings.append("有索引记录缺少对应目录，未将其当作可完整导出的内容。") }
        }
        let known = Set(records.map(\.key))
        for item in entries where item.isFolder && !item.name.hasPrefix(".") && !known.contains(item.name) {
            try validateComponent(item.name)
            items.append(.init(id: item.name, title: "未编入索引的目录 " + item.name, path: [item.name], isDirectory: true,
                               modified: item.modified))
        }
        let captured = ContentSource(connection: source.connection, deviceScope: source.deviceScope, path: source.path,
                                     kind: .notes, displayName: source.displayName, revision: index.sha256,
                                     resumeIdentity: source.resumeIdentity, resumeVolume: source.resumeVolume,
                                     wirelessSource: source.wirelessSource)
        return .init(source: captured, items: items, warnings: Array(Set(warnings)).sorted())
    }

    public static func validateNoteRevision(_ source: ContentSource, root: DeviceFolder, device: any DeviceConnection) async throws {
        guard source.kind == .notes else { return }
        let directory = try await folder(source.path, from: root, device: device)
        let index = try await noteIndex(in: directory, device: device)
        defer { try? FileManager.default.removeItem(at: index.directory) }
        guard let expected = source.revision, index.sha256 == expected else {
            throw ToolboxError.message("笔记索引已变化，请重新扫描并创建导出任务")
        }
    }

    private static func noteIndex(in root: DeviceFolder, device: any DeviceConnection) async throws
        -> (file: URL, directory: URL, sha256: String) {
        let database = try await folder([".database"], from: root, device: device)
        let temporary = FileManager.default.temporaryDirectory.appending(path: "Hanvon-Content-Index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try await checkTransactions(in: database, device: device)
            let source = try await entry("HvNote.db", in: database, device: device)
            guard let size = source.size, size <= 16 * 1024 * 1024 else { throw ToolboxError.unsupported("笔记索引大小未知或超过 16 MiB") }
            let file = temporary.appending(path: "HvNote.db")
            try await device.download(source, to: file, progress: nil)
            let check = temporary.appending(path: "check.db")
            try await device.download(try await entry("HvNote.db", in: database, device: device), to: check, progress: nil)
            let hash = try await fingerprint(file)
            guard hash == (try await fingerprint(check)) else { throw ToolboxError.message("笔记索引仍在变化，请保存并退出编辑后再扫描") }
            try await checkTransactions(in: database, device: device)
            return (file, temporary, hash)
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    public static func checkTransactions(in folder: DeviceFolder, device: any DeviceConnection) async throws {
        for item in try await device.list(folder) {
            if item.name.hasSuffix("-wal") || item.name.hasSuffix("-journal") {
                guard item.size == 0 else { throw ToolboxError.message("来源数据库有活动事务，请保存并退出编辑后重新准备") }
            }
        }
    }

    public static func fingerprint(_ file: URL) async throws -> String {
        let task = Task.detached {
            try Task.checkCancellation()
            let hash = try DirectorySync.fingerprint(of: file)
            return hash.sha256.map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public static func inventory(item: ExportContentItem, source: ContentSource, root: DeviceFolder,
                                 device: any DeviceConnection) async throws -> (files: [ContentExportResource], directories: [[String]]) {
        let sourceRoot = try await folder(source.path, from: root, device: device)
        var files: [ContentExportResource] = [], directories: [[String]] = []
        var visited = Set<DeviceFolder>(), names = Set<String>(), count = 0
        func add(_ path: [String]) throws {
            count += 1
            guard count <= 20_000, path.count <= 64 else { throw ToolboxError.unsupported("来源超过文件数量或目录深度限制") }
            for name in path { try validateComponent(name) }
            let key = path.map(DirectorySync.nameKey).joined(separator: "/")
            guard names.insert(key).inserted else { throw ToolboxError.message("来源存在大小写或 Unicode 重名，未开始导出") }
        }
        func walk(_ folder: DeviceFolder, path: [String]) async throws {
            try Task.checkCancellation()
            guard visited.insert(folder).inserted else { throw ToolboxError.invalidResponse("来源包含循环目录") }
            try await checkTransactions(in: folder, device: device)
            for child in try await device.list(folder) {
                let relative = path + [child.name]
                try add(relative)
                if let nested = child.folder {
                    directories.append(relative)
                    try await walk(nested, path: relative)
                } else { files.append(.init(path: relative, size: child.size, modified: child.modified)) }
            }
        }
        if item.isDirectory {
            let folder = try await folder(item.path, from: sourceRoot, device: device)
            try await walk(folder, path: [])
        } else {
            guard let name = item.path.last else { throw ToolboxError.message("文件来源无效") }
            let parent = try await folder(Array(item.path.dropLast()), from: sourceRoot, device: device)
            let file = try await entry(name, in: parent, device: device)
            guard !file.isFolder else { throw ToolboxError.message("来源文件类型已改变") }
            try add([name]); files.append(.init(path: [name], size: file.size, modified: file.modified))
        }
        return (files.sorted { $0.path.lexicographicallyPrecedes($1.path) },
                directories.sorted { $0.lexicographicallyPrecedes($1) })
    }

    public static func resource(_ resource: ContentExportResource, item: ExportContentItem, source: ContentSource,
                                root: DeviceFolder, device: any DeviceConnection) async throws -> DeviceItem {
        let base = source.path + (item.isDirectory ? item.path : Array(item.path.dropLast()))
        let folder = try await folder(base + resource.path.dropLast(), from: root, device: device)
        let entry = try await entry(resource.path.last ?? "", in: folder, device: device)
        guard !entry.isFolder, entry.size == resource.size, entry.modified == resource.modified else {
            throw ToolboxError.message("源文件的大小、时间或类型已变化，请重新扫描")
        }
        return entry
    }
}
