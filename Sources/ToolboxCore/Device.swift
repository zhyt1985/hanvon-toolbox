import Foundation

public enum ConnectionKind: String, Codable, Sendable {
    case usb = "USB"
    case wifi = "Wi-Fi"
    case companion = "无线管理"
}

public enum DeviceFolder: Codable, Hashable, Sendable {
    case usb(storage: UInt32, parent: UInt32)
    case wifi(path: String?)
    case companion(path: String)
}

public struct DeviceVolume: Identifiable, Sendable {
    public var id: DeviceFolder { root }
    public let name: String
    public let root: DeviceFolder
    public let capacity: UInt64?
    public let freeSpace: UInt64?
    public let identity: String?

    public init(name: String, root: DeviceFolder, capacity: UInt64? = nil, freeSpace: UInt64? = nil,
                identity: String? = nil) {
        self.name = name
        self.root = root
        self.capacity = capacity
        self.freeSpace = freeSpace
        self.identity = identity
    }
}

public struct DeviceInfo: Sendable {
    public struct Field: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public let name: String
    public let fields: [Field]
    public let volumes: [DeviceVolume]
    public let supportsAPK: Bool
    public let canManageFiles: Bool
    public let supportsRecoveryCleanup: Bool
    public let supportsFileOperations: Bool
    public let supportsResumableTransfers: Bool
    public let supportsContentSources: Bool
    public let supportsContentSnapshots: Bool

    public init(name: String, fields: [Field], volumes: [DeviceVolume], supportsAPK: Bool, canManageFiles: Bool,
                supportsRecoveryCleanup: Bool = false, supportsFileOperations: Bool = false,
                supportsResumableTransfers: Bool = false, supportsContentSources: Bool = false, supportsContentSnapshots: Bool = false) {
        self.name = name
        self.fields = fields
        self.volumes = volumes
        self.supportsAPK = supportsAPK
        self.canManageFiles = canManageFiles
        self.supportsRecoveryCleanup = supportsRecoveryCleanup
        self.supportsFileOperations = supportsFileOperations
        self.supportsResumableTransfers = supportsResumableTransfers
        self.supportsContentSources = supportsContentSources
        self.supportsContentSnapshots = supportsContentSnapshots
    }
}

public struct DeviceItem: Identifiable, Hashable, Sendable {
    public enum ID: Hashable, Sendable {
        case usb(storage: UInt32, handle: UInt32)
        case wifi(path: String)
        case companion(path: String)
    }

    public let id: ID
    public let name: String
    public let folder: DeviceFolder?
    public let size: UInt64?
    public let sizeLabel: String?
    public let modified: Date?
    public var isFolder: Bool { folder != nil }

    public init(id: ID, name: String, folder: DeviceFolder? = nil, size: UInt64? = nil, sizeLabel: String? = nil,
                modified: Date? = nil) {
        self.id = id
        self.name = name
        self.folder = folder
        self.size = size
        self.sizeLabel = sizeLabel
        self.modified = modified
    }
}

public struct TransferProgress: Sendable {
    public let completed: UInt64
    public let total: UInt64?
    public let resumedFrom: UInt64?

    public init(completed: UInt64, total: UInt64?, resumedFrom: UInt64? = nil) {
        self.completed = completed
        self.total = total
        self.resumedFrom = resumedFrom
    }
}

public typealias ProgressUpdate = @Sendable (TransferProgress) -> Void

public enum ToolboxError: LocalizedError, Sendable {
    case message(String)
    case usbLink(String)
    case wirelessUnavailable
    case wirelessIdentityMismatch
    case mtp(UInt16, UInt16)
    case invalidResponse(String)
    case conflict(String)
    case unsupported(String)
    case pairingExpired
    case remoteItemMissing

    public var errorDescription: String? {
        switch self {
        case let .message(text), let .usbLink(text), let .unsupported(text):
            text
        case .wirelessUnavailable:
            "暂时无法访问伴侣应用。请确认设备已开启无线管理，且 Mac 和电纸书处于同一局域网。"
        case .wirelessIdentityMismatch:
            "无法验证电纸书的 HTTPS 身份。请检查地址和设备指纹。"
        case let .mtp(operation, status):
            String(format: "设备拒绝了 MTP 请求（%04X → %04X）。", operation, status)
        case let .invalidResponse(detail):
            "设备响应异常。\(detail)"
        case .pairingExpired:
            "设备上的配对已失效，请重新输入设备指纹和配对码。"
        case .remoteItemMissing:
            "未找到所选文件或目录。"
        case let .conflict(name):
            "目标中已有同名项目「\(name)」。"
        }
    }

    public var needsReconnect: Bool {
        switch self {
        case .usbLink, .wirelessUnavailable: true
        default: false
        }
    }
}

public protocol DeviceConnection: Sendable {
    var kind: ConnectionKind { get }
    func info() async throws -> DeviceInfo
    func list(_ folder: DeviceFolder) async throws -> [DeviceItem]
    func download(_ item: DeviceItem, to destination: URL, progress: ProgressUpdate?) async throws
    func upload(_ file: URL, to folder: DeviceFolder, progress: ProgressUpdate?) async throws
    func makeFolder(named name: String, in folder: DeviceFolder) async throws -> DeviceItem
    func rename(_ item: DeviceItem, in folder: DeviceFolder, to name: String) async throws
    func delete(_ item: DeviceItem) async throws
    func relocate(_ item: DeviceItem, to folder: DeviceFolder, copying: Bool) async throws
    func requestAPKInstall(_ apk: URL, progress: ProgressUpdate?) async throws
    func cleanupRecoveryCopy(in folder: DeviceFolder, request: RecoveryCopyCleanup) async throws -> Bool
    func uploadResumable(_ file: URL, to folder: DeviceFolder, transferID: UUID, progress: ProgressUpdate?) async throws
    func downloadResumable(_ item: DeviceItem, to destination: URL, transferID: UUID, progress: ProgressUpdate?) async throws
    func discardResumable(_ transferID: UUID) async throws
    func close() async
}

public extension DeviceConnection {
    func uploadResumable(_ file: URL, to folder: DeviceFolder, transferID: UUID, progress: ProgressUpdate?) async throws {
        if try hasName(await list(folder), file.lastPathComponent) { throw ToolboxError.conflict(file.lastPathComponent) }
        try await FileTransfers.uploadFile(file, to: folder, on: self, progress: progress)
    }
    func downloadResumable(_ item: DeviceItem, to destination: URL, transferID: UUID, progress: ProgressUpdate?) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ToolboxError.conflict(item.name) }
        try await download(item, to: destination, progress: progress)
    }
    func discardResumable(_ transferID: UUID) async throws {}
    func makeFolder(named name: String, in folder: DeviceFolder) async throws -> DeviceItem {
        throw ToolboxError.unsupported("此连接不支持新建目录。")
    }
    func rename(_ item: DeviceItem, in folder: DeviceFolder, to name: String) async throws {
        throw ToolboxError.unsupported("此连接不支持重命名。")
    }
    func delete(_ item: DeviceItem) async throws {
        throw ToolboxError.unsupported("此连接不支持从目录删除文件。")
    }
    func relocate(_ item: DeviceItem, to folder: DeviceFolder, copying: Bool) async throws {
        throw ToolboxError.unsupported("此连接不支持目录内复制或移动。")
    }
    func requestAPKInstall(_ apk: URL, progress: ProgressUpdate?) async throws {
        throw ToolboxError.unsupported("此连接不支持发起 APK 安装。")
    }
}

public func validateFileName(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..",
          name.utf16.count <= 254, !name.contains("/"), !name.contains("\0") else {
        throw ToolboxError.message("请输入有效的文件或目录名。")
    }
}

func hasName(_ items: [DeviceItem], _ name: String, except: DeviceItem.ID? = nil) -> Bool {
    items.contains { item in
        item.id != except && item.name.compare(name, options: [.caseInsensitive]) == .orderedSame
    }
}

func listOrder(_ left: DeviceItem, _ right: DeviceItem) -> Bool {
    if left.isFolder != right.isFolder { return left.isFolder }
    return left.name.localizedStandardCompare(right.name) == .orderedAscending
}

func createTransferFile(in directory: URL) throws -> URL {
    let file = directory.appendingPathComponent(".hanvon-transfer-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
        throw ToolboxError.message("无法创建临时传输文件。")
    }
    return file
}
