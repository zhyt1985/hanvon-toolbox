import Foundation

public enum ContentSourceAccessError: LocalizedError, Sendable, Equatable {
    case denied, changed, missing, unsupported
    public var errorDescription: String? {
        switch self {
        case .denied: "内容来源未授权、已撤销或系统权限失效。请在电纸书核对请求并允许只读访问。"
        case .changed: "内容来源版本已改变，请刷新来源并重新扫描；旧任务不会读取新授权。"
        case .missing: "内容来源、请求或续传记录已不存在，请刷新后重新开始。"
        case .unsupported: "专用无线内容来源需要伴侣 0.6.0 或更新版本。原文件管理继续可用。"
        }
    }
}

public struct CompanionContentSource: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let revision: String
    public let name: String
    public let kind: ContentSourceKind
    public let authorized: Bool
    public let readable: Bool
    public var cacheIdentity: String { "content/" + id + "/" + revision }
    public func binding(deviceID: String) -> String { deviceID + "/" + cacheIdentity }
    public init(id: String, revision: String, name: String, kind: ContentSourceKind, authorized: Bool, readable: Bool) {
        self.id = id; self.revision = revision; self.name = name; self.kind = kind
        self.authorized = authorized; self.readable = readable
    }
    public func validate() throws {
        guard Self.validID(id), Self.validID(revision), !name.isEmpty, name.utf8.count <= 4096 else {
            throw ToolboxError.invalidResponse("内容来源身份无效")
        }
    }
    static func validID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

public struct CompanionContentAccessRequest: Decodable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let code: String
    public let state: String
    static func decode(_ data: Data, sourceID: String) throws -> Self {
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard CompanionContentSource.validID(request.id), request.sourceID == sourceID,
              request.code.count == 6, request.code.utf8.allSatisfy({ (48...57).contains($0) }),
              ["pending", "approved", "denied"].contains(request.state) else {
            throw ToolboxError.invalidResponse("内容访问请求无效")
        }
        return request
    }
}

/// A virtual, read-only connection. It never forwards mutations to the management root.
public final class CompanionContentDevice: DeviceConnection, Sendable {
    public let kind = ConnectionKind.companion
    public let source: CompanionContentSource
    let deviceID: String
    public let supportsSnapshots: Bool
    let wire: ResumeWire
    let cacheBase: URL?
    init(source: CompanionContentSource, deviceID: String, supportsSnapshots: Bool = false, wire: ResumeWire, cacheBase: URL? = nil) throws {
        try source.validate()
        guard source.authorized, source.readable else { throw ContentSourceAccessError.denied }
        self.source = source; self.deviceID = deviceID; self.wire = wire; self.supportsSnapshots = supportsSnapshots
        self.cacheBase = cacheBase
    }
    private var scopedWire: ResumeWire {
        .init(send: { [self] method, route, query, body in
            guard body == nil, ["resume/download/info", "resume/download/chunk", "resume/abort"].contains(route) else {
                throw ToolboxError.unsupported("内容来源仅支持读取")
            }
            return try await wire.send(method, route,
                query + [("sourceID", source.id), ("revision", source.revision)], nil)
        })
    }
    public func info() async throws -> DeviceInfo {
        let data = try await wire.send("GET", "sources", [], nil)
        let sources = try JSONDecoder().decode([CompanionContentSource].self, from: data)
        guard let current = sources.first(where: { $0.id == source.id }) else { throw ContentSourceAccessError.missing }
        guard current.revision == source.revision else { throw ContentSourceAccessError.changed }
        guard current.authorized, current.readable else { throw ContentSourceAccessError.denied }
        return .init(name: source.name, fields: [.init("来源", "专用只读内容来源")],
                     volumes: [.init(name: source.name, root: .companion(path: ""), identity: source.cacheIdentity)],
                     supportsAPK: false, canManageFiles: false, supportsResumableTransfers: true)
    }
    public func list(_ folder: DeviceFolder) async throws -> [DeviceItem] {
        guard case let .companion(path) = folder else { throw ToolboxError.message("内容来源目录无效") }
        try validatePath(path, allowRoot: true)
        struct Row: Decodable { let name: String; let directory: Bool; let size: UInt64?; let modified: Double? }
        let data = try await wire.send("GET", "list",
            [("sourceID", source.id), ("revision", source.revision), ("path", path)], nil)
        let rows = try JSONDecoder().decode([Row].self, from: data)
        guard rows.count <= 20_000 else { throw ToolboxError.unsupported("内容来源目录超过限制") }
        var seen = Set<String>()
        return try rows.map { row in
            try ContentReader.validateComponent(row.name)
            guard seen.insert(DirectorySync.nameKey(row.name)).inserted else { throw ToolboxError.invalidResponse("来源存在重名") }
            let joined = path.isEmpty ? row.name : path + "/" + row.name
            return .init(id: .companion(path: joined), name: row.name,
                         folder: row.directory ? .companion(path: joined) : nil, size: row.size,
                         modified: row.modified.map { Date(timeIntervalSince1970: $0 / 1000) })
        }.sorted(by: listOrder)
    }
    public func download(_ item: DeviceItem, to file: URL, progress: ProgressUpdate?) async throws {
        let id = UUID()
        do { try await downloadResumable(item, to: file, transferID: id, progress: progress) }
        catch {
            ResumableTransfers.discard(scope: deviceID + "/" + source.cacheIdentity, id: id, base: cacheBase)
            _ = try? await scopedWire.send("POST", "resume/abort", [("id", id.uuidString)], nil)
            throw error
        }
    }
    public func downloadResumable(_ item: DeviceItem, to file: URL, transferID: UUID, progress: ProgressUpdate?) async throws {
        guard case let .companion(path) = item.id, !item.isFolder else { throw ToolboxError.message("请选择普通内容文件") }
        try validatePath(path, allowRoot: false)
        try await ResumableTransfers.download(path: path, destination: file,
            scope: deviceID + "/" + source.cacheIdentity, id: transferID, wire: scopedWire, progress: progress, base: cacheBase)
    }
    public func discardResumable(_ id: UUID) async throws {
        ResumableTransfers.discard(scope: deviceID + "/" + source.cacheIdentity, id: id, base: cacheBase)
        _ = try await scopedWire.send("POST", "resume/abort", [("id", id.uuidString)], nil)
    }
    public func upload(_ file: URL, to folder: DeviceFolder, progress: ProgressUpdate?) async throws {
        throw ToolboxError.unsupported("内容来源仅支持读取，不能上传")
    }
    public func requestAPKInstall(_ apk: URL, progress: ProgressUpdate?) async throws {
        throw ToolboxError.unsupported("内容来源不能接收 APK 安装请求")
    }
    public func close() async {}
    private func validatePath(_ path: String, allowRoot: Bool) throws {
        if path.isEmpty && allowRoot { return }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 64 else { throw ToolboxError.message("内容路径无效") }
        for part in parts { try ContentReader.validateComponent(String(part)) }
    }
}
