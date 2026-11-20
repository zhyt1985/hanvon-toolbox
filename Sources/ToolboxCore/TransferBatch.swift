import Foundation

public struct TransferStep: Identifiable, Codable, Sendable {
    public enum Action: Codable, Sendable {
        case upload(URL, directories: [String])
        case syncUpload(path: [String], stamp: DirectorySync.FileStamp)
        case syncEmptyFolder(path: [String], direction: DirectorySync.Direction)
        case syncConflict
        case syncUpdate(SyncUpdate)
        case makeDeviceFolders([String])
        case download(path: [String], expectedSize: UInt64?)
        case makeLocalFolders([String])
        case apk(URL)
    }

    public let id: UUID
    public let name: String
    public let action: Action
    public var isResumableFile: Bool {
        switch action {
        case .upload, .download, .syncUpload: true
        default: false
        }
    }

    public init(name: String, action: Action) {
        self.id = UUID()
        self.name = name
        self.action = action
    }
}

public enum TransferResult: Codable, Equatable, Sendable {
    case waiting
    case running
    case succeeded
    case skipped(String)
    case failed(String)
    case interrupted(String)
    case cancelled

    public var canRetry: Bool {
        switch self {
        case .waiting, .failed, .interrupted: true
        case .running, .succeeded, .skipped, .cancelled: false
        }
    }
}

public enum TransferBatch {
    public static func planUpload(_ sources: [URL], kind: ConnectionKind) async throws -> [TransferStep] {
        let task = Task.detached(priority: .userInitiated) {
            try sources.flatMap { try uploadSteps($0, parents: [], kind: kind) }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public static func planDownload(
        _ sources: [DeviceItem], device: any DeviceConnection
    ) async throws -> [TransferStep] {
        var steps: [TransferStep] = []
        for source in sources {
            try await appendDownload(source, parents: [], visited: [], device: device, steps: &steps)
        }
        return steps
    }

    public static func reconnectError(_ error: any Error) -> Bool {
        if let toolbox = error as? ToolboxError {
            if case .pairingExpired = toolbox { return true }
            return toolbox.needsReconnect
        }
        guard let url = error as? URLError else { return false }
        return [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .callIsActive].contains(url.code)
    }

    @discardableResult
    public static func run(
        _ steps: [TransferStep], executor: TransferExecutor, progress: ProgressUpdate?,
        report: @Sendable (UUID, TransferResult) async -> Void
    ) async -> (any Error)? {
        for step in steps {
            if Task.isCancelled { return CancellationError() }
            await report(step.id, .running)
            do {
                try await executor.execute(step, progress: progress)
                await report(step.id, .succeeded)
            } catch ToolboxError.conflict(let name) {
                if case .syncUpdate = step.action {
                    await report(step.id, .failed("文件名「\(name)」已改变，请核对后重试。"))
                } else {
                    await report(step.id, .skipped("已保留同名项目「\(name)」。"))
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    await report(step.id, .interrupted("已取消，可重试此项。"))
                    return error
                }
                if reconnectError(error) {
                    await report(step.id, .interrupted(error.localizedDescription))
                    return error
                }
                await report(step.id, .failed(error.localizedDescription))
            }
        }
        return nil
    }

    private static func uploadSteps(_ url: URL, parents: [String], kind: ConnectionKind) throws -> [TransferStep] {
        try Task.checkCancellation()
        try validateFileName(url.lastPathComponent)
        let path = parents + [url.lastPathComponent]
        let name = path.joined(separator: "/")
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if kind == .wifi || values.isDirectory != true || values.isSymbolicLink == true {
            return [.init(name: name, action: .upload(url, directories: parents))]
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if children.isEmpty { return [.init(name: name, action: .makeDeviceFolders(path))] }
        return try children.flatMap { try uploadSteps($0, parents: path, kind: kind) }
    }

    private static func appendDownload(
        _ item: DeviceItem, parents: [String], visited: Set<DeviceFolder>,
        device: any DeviceConnection, steps: inout [TransferStep]
    ) async throws {
        try Task.checkCancellation()
        try validateFileName(item.name)
        let path = parents + [item.name]
        let name = path.joined(separator: "/")
        guard let folder = item.folder else {
            steps.append(.init(name: name, action: .download(path: path, expectedSize: item.size)))
            return
        }
        guard !visited.contains(folder) else { throw ToolboxError.invalidResponse("设备返回了循环目录。") }
        let children = try await device.list(folder)
        if children.isEmpty { steps.append(.init(name: name, action: .makeLocalFolders(path))) }
        for child in children {
            try await appendDownload(child, parents: path, visited: visited.union([folder]), device: device, steps: &steps)
        }
    }
}

public struct TransferExecutor: Sendable {
    public let device: any DeviceConnection
    public let volumeRoot: DeviceFolder
    public let devicePath: [String]
    public let localRoot: URL?
    public let syncRoot: DirectorySync.LocalRoot?
    public let backupScope: SyncBackupScope?
    public let backups: SyncBackupStore

    public init(device: any DeviceConnection, volumeRoot: DeviceFolder, devicePath: [String], localRoot: URL? = nil,
                syncRoot: DirectorySync.LocalRoot? = nil, backupScope: SyncBackupScope? = nil,
                backups: SyncBackupStore = .shared) {
        self.device = device
        self.volumeRoot = volumeRoot
        self.devicePath = devicePath
        self.localRoot = localRoot
        self.syncRoot = syncRoot
        self.backupScope = backupScope
        self.backups = backups
    }

    public func execute(_ step: TransferStep, progress: ProgressUpdate?) async throws {
        try Task.checkCancellation()
        try syncRoot?.validate()
        switch step.action {
        case let .syncUpdate(update):
            try await executeUpdate(update, id: step.id, progress: progress)
        case let .upload(file, directories):
            let target = try await deviceFolder(directories, create: true)
            try await device.uploadResumable(file, to: target, transferID: step.id, progress: progress)
        case let .syncUpload(path, stamp):
            guard let syncRoot, let name = path.last else {
                throw ToolboxError.message("未找到同步源文件的位置。")
            }
            let directories = Array(path.dropLast())
            let parent = try localFolder(directories, root: syncRoot.url, create: false)
            try validateFileName(name)
            guard try matchingLocalName(name, in: parent) != nil else {
                throw ToolboxError.message("Mac 源文件已移动，请重新比较。")
            }
            let source = parent.appendingPathComponent(name)
            try stamp.validate(source)
            let target = try await deviceFolder(directories, create: true)
            if device.kind != .companion, try matchingDeviceItem(name, in: await device.list(target)) != nil {
                throw ToolboxError.conflict(name)
            }
            try stamp.validate(source)
            try await device.uploadResumable(source, to: target, transferID: step.id, progress: progress)
        case let .syncEmptyFolder(path, direction):
            guard let syncRoot, !path.isEmpty else {
                throw ToolboxError.message("未找到同步源目录的位置。")
            }
            switch direction {
            case .toDevice:
                let source = try localFolder(path, root: syncRoot.url, create: false)
                guard try FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty else {
                    throw ToolboxError.message("Mac 源目录已改变，请重新比较。")
                }
                _ = try await deviceFolder(path, create: true)
            case .toMac:
                let source = try await deviceFolder(path, create: false)
                guard try await device.list(source).isEmpty else {
                    throw ToolboxError.message("电纸书源目录已改变，请重新比较。")
                }
                _ = try localFolder(path, root: localRoot, create: true)
            }
        case .syncConflict:
            throw ToolboxError.conflict(step.name)
        case let .makeDeviceFolders(path):
            _ = try await deviceFolder(path, create: true)
        case let .download(path, expectedSize):
            guard let name = path.last else { throw ToolboxError.message("没有指定文件。") }
            try validateFileName(name)
            let directories = Array(path.dropLast())
            let parent = try await deviceFolder(directories, create: false)
            let entries = try await device.list(parent)
            let file = syncRoot == nil ? entries.first { $0.name == name && !$0.isFolder }
                : try matchingDeviceItem(name, in: entries)
            guard let item = file, !item.isFolder else {
                throw ToolboxError.message("设备上的源文件不存在。")
            }
            if let expectedSize, let actual = item.size, expectedSize != actual {
                throw ToolboxError.message("设备上的源文件大小已改变，请重新选择此文件。")
            }
            let destination = try localFolder(directories, root: localRoot, create: true)
            if syncRoot != nil, device.kind != .companion, try matchingLocalName(name, in: destination) != nil {
                throw ToolboxError.conflict(name)
            }
            try await device.downloadResumable(item, to: destination.appendingPathComponent(name), transferID: step.id, progress: progress)
        case let .makeLocalFolders(path):
            _ = try localFolder(path, root: localRoot, create: true)
        case let .apk(apk):
            if device.kind == .companion {
                try await device.requestAPKInstall(apk, progress: progress)
            } else {
                try await FileTransfers.sendAPK(apk, to: volumeRoot, on: device, progress: progress)
            }
        }
    }

    func deviceFolder(_ path: [String], create: Bool) async throws -> DeviceFolder {
        if device.kind == .wifi && create { return volumeRoot }
        var folder = volumeRoot
        for name in devicePath {
            let entries = try await device.list(folder)
            guard let next = try matchingDeviceItem(name, in: entries)?.folder else {
                throw ToolboxError.message("原设备目录「\(name)」已不可用。")
            }
            folder = next
        }
        for name in path {
            let entries = try await device.list(folder)
            if let match = try matchingDeviceItem(name, in: entries) {
                guard let next = match.folder else { throw ToolboxError.conflict(name) }
                folder = next
            } else {
                guard create else { throw ToolboxError.message("设备目录「\(name)」已不可用。") }
                if hasName(entries, name) { throw ToolboxError.conflict(name) }
                let added = try await device.makeFolder(named: name, in: folder)
                guard let next = added.folder else { throw ToolboxError.invalidResponse("设备未返回新目录。") }
                folder = next
            }
        }
        return folder
    }

    func matchingDeviceItem(_ name: String, in entries: [DeviceItem]) throws -> DeviceItem? {
        guard syncRoot != nil else { return entries.first { $0.name == name } }
        let key = DirectorySync.nameKey(name)
        let matches = entries.filter { DirectorySync.nameKey($0.name) == key }
        if let first = matches.first, matches.count != 1 || first.name != name {
            throw ToolboxError.conflict(name)
        }
        return matches.first
    }

    func matchingLocalName(_ name: String, in parent: URL) throws -> String? {
        let key = DirectorySync.nameKey(name)
        let matches = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
            DirectorySync.nameKey($0) == key
        }
        if let first = matches.first, matches.count != 1 || first != name {
            throw ToolboxError.conflict(name)
        }
        return matches.first
    }

    func localFolder(_ path: [String], root: URL?, create: Bool) throws -> URL {
        guard var directory = root,
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ToolboxError.message("原 Mac 目标目录已不可用。")
        }
        for name in path {
            try validateFileName(name)
            if syncRoot != nil { _ = try matchingLocalName(name, in: directory) }
            directory.appendPathComponent(name, isDirectory: true)
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            if let existing = try? directory.resourceValues(forKeys: keys) {
                guard existing.isDirectory == true, existing.isSymbolicLink != true else {
                    throw ToolboxError.conflict(name)
                }
            } else {
                guard create else { throw ToolboxError.message("Mac 源目录已改变，请重新比较。") }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    throw ToolboxError.conflict(name)
                }
            }
        }
        return directory
    }
}
