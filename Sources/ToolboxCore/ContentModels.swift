import CryptoKit
import Foundation

public enum ContentSourceKind: String, Codable, Sendable { case notes, files }

public struct ContentSource: Codable, Equatable, Sendable {
    public let connection: ConnectionKind
    public let deviceScope: String
    public let path: [String]
    public let kind: ContentSourceKind
    public let displayName: String
    public let revision: String?
    public let resumeIdentity: String?
    public let resumeVolume: String?
    public let wirelessSource: CompanionContentSource?
    public var id: String {
        let data = (try? JSONEncoder().encode(path)) ?? Data()
        return SHA256.hash(data: Data((connection.rawValue + "/" + deviceScope + "/" + kind.rawValue).utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }
    public init(connection: ConnectionKind, deviceScope: String, path: [String],
                kind: ContentSourceKind, displayName: String, revision: String? = nil,
                resumeIdentity: String? = nil, resumeVolume: String? = nil, wirelessSource: CompanionContentSource? = nil) {
        self.connection = connection; self.deviceScope = deviceScope; self.path = path
        self.kind = kind; self.displayName = displayName
        self.revision = revision
        self.resumeIdentity = resumeIdentity; self.resumeVolume = resumeVolume
        self.wirelessSource = wirelessSource
    }
}

public struct ExportContentItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let path: [String]
    public let isDirectory: Bool
    public let byteCount: UInt64?
    public let modified: Date?
    public let noteType: Int64?
    public let protected: Bool
    public let indexed: Bool
    public init(id: String, title: String, path: [String], isDirectory: Bool, byteCount: UInt64? = nil,
                modified: Date? = nil, noteType: Int64? = nil, protected: Bool = false, indexed: Bool = false) {
        self.id = id; self.title = title; self.path = path; self.isDirectory = isDirectory
        self.byteCount = byteCount; self.modified = modified; self.noteType = noteType
        self.protected = protected; self.indexed = indexed
    }
}

public struct ContentCatalog: Codable, Sendable {
    public let source: ContentSource
    public let scannedAt: Date
    public let items: [ExportContentItem]
    public let warnings: [String]
    public init(source: ContentSource, items: [ExportContentItem], warnings: [String] = []) {
        self.source = source; self.scannedAt = Date(); self.items = items; self.warnings = warnings
    }
}

public struct ContentExportResource: Codable, Equatable, Sendable {
    public let id: UUID
    public let path: [String]
    public let size: UInt64?
    public let modified: Date?
    public var sha256: String?
    public var downloaded = false
    public init(path: [String], size: UInt64?, modified: Date?) {
        id = UUID(); self.path = path; self.size = size; self.modified = modified
    }
}

public enum ContentExportState: String, Codable, Sendable {
    case waiting, preparing, transferring, verifying, completed, limited, failed, interrupted, cancelled
    public var isFinished: Bool { [.completed, .limited, .cancelled].contains(self) }
    public var label: String {
        switch self {
        case .waiting: "等待"
        case .preparing: "正在准备"
        case .transferring: "正在下载"
        case .verifying: "正在校验"
        case .completed: "完成"
        case .limited: "目录副本完成"
        case .failed: "失败"
        case .interrupted: "已中断"
        case .cancelled: "已取消"
        }
    }
}

public struct ContentExportRow: Identifiable, Codable, Sendable {
    public let id: UUID
    public let item: ExportContentItem
    public var state: ContentExportState = .waiting
    public var message: String?
    public var resources: [ContentExportResource]?
    public var directories: [[String]] = []
    public var snapshot: ContentSnapshotReference?
    public var outputName: String
    public init(item: ExportContentItem) {
        id = UUID(); self.item = item
        var title = String(item.title.prefix(65)).map { "/:\\\0".contains($0) || $0.isNewline ? "_" : String($0) }.joined()
        while title.utf8.count > 140 { title.removeLast() }
        outputName = (title.isEmpty ? "未命名内容" : title) + "--" + id.uuidString.prefix(8) + ".hanvonexport"
    }
}

public struct ContentExportJob: Identifiable, Codable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let source: ContentSource
    public let output: URL
    public var paused: Bool
    public var rows: [ContentExportRow]
    public init(source: ContentSource, items: [ExportContentItem], parent: URL) {
        schemaVersion = 1; id = UUID(); createdAt = Date(); self.source = source; paused = false
        output = parent.resolvingSymlinksInPath().appending(path: "内容导出-" + id.uuidString, directoryHint: .isDirectory)
        rows = items.map(ContentExportRow.init)
    }
}

public struct ContentExportManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let jobID: UUID
    public let rowID: UUID
    public let createdAt: Date
    public let source: ContentSource
    public let item: ExportContentItem
    public let resources: [ContentExportResource]
    public let directories: [[String]]
    public let capture: String
    public let limitations: [String]
    public var snapshot: ContentSnapshotReference? = nil
}
