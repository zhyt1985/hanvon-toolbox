import Foundation

public enum FileTransfers {
    public static func clearResumableCache(deviceIdentity: String, volumeIdentity: String, transferID: UUID) {
        ResumableTransfers.discard(scope: deviceIdentity + "/" + volumeIdentity, id: transferID)
    }
    public static func upload(
        _ source: URL, to folder: DeviceFolder, on device: any DeviceConnection, progress: ProgressUpdate?
    ) async throws {
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ToolboxError.unsupported("请直接选择文件，跳过符号链接。") }
        if values.isDirectory == true {
            guard device.kind != .wifi else { throw ToolboxError.unsupported("文件夹上传需使用 USB 或无线管理。") }
            let created = try await device.makeFolder(named: source.lastPathComponent, in: folder)
            guard let child = created.folder else {
                throw ToolboxError.invalidResponse("新建目录没有返回可浏览位置。")
            }
            let entries = try FileManager.default.contentsOfDirectory(
                at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
            )
            for entry in entries {
                try await upload(entry, to: child, on: device, progress: progress)
            }
        } else {
            try await uploadFile(source, to: folder, on: device, progress: progress)
        }
    }

    static func uploadFile(
        _ file: URL, to folder: DeviceFolder, on device: any DeviceConnection, progress: ProgressUpdate?
    ) async throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ToolboxError.unsupported("请选择普通文件。Wi-Fi 传书仅支持上传文件。")
        }
        try await device.upload(file, to: folder, progress: progress)
    }

    public static func download(
        _ item: DeviceItem, to localFolder: URL, on device: any DeviceConnection, progress: ProgressUpdate?
    ) async throws {
        try await download(item, to: localFolder, on: device, progress: progress, ancestors: [])
    }

    private static func download(
        _ item: DeviceItem, to localFolder: URL, on device: any DeviceConnection, progress: ProgressUpdate?,
        ancestors: Set<DeviceFolder>
    ) async throws {
        try Task.checkCancellation()
        try validateFileName(item.name)
        let destination = localFolder.appendingPathComponent(item.name, isDirectory: item.isFolder)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolboxError.conflict(item.name)
        }
        if let folder = item.folder {
            guard !ancestors.contains(folder) else {
                throw ToolboxError.invalidResponse("设备返回了循环目录。")
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try await device.list(folder) {
                try await download(child, to: destination, on: device, progress: progress, ancestors: ancestors.union([folder]))
            }
        } else {
            try await device.download(item, to: destination, progress: progress)
        }
    }
}

public extension FileTransfers {
    static func sendAPK(
        _ apk: URL, to root: DeviceFolder, on device: any DeviceConnection, progress: ProgressUpdate?
    ) async throws {
        guard device.kind == .usb, case .usb(storage: _, parent: UInt32.max) = root else {
            throw ToolboxError.unsupported("请通过 USB 连接后选择设备存储。")
        }
        try validateAPK(apk)
        let folders = try await device.list(root)
        guard let download = folders.first(where: { $0.name == "Download" })?.folder else {
            throw ToolboxError.message("选中的设备存储中没有 Download 文件夹。")
        }
        try await device.upload(apk, to: download, progress: progress)
    }
}

extension FileTransfers {
    static func validateAPK(_ apk: URL) throws {
        guard apk.pathExtension.lowercased() == "apk" else {
            throw ToolboxError.message("请选择 .apk 安装包。")
        }
        let file = try FileHandle(forReadingFrom: apk)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw ToolboxError.message("这个文件没有有效的 APK 容器头。")
        }
    }
}
