import Foundation

public struct ContentSnapshotReference: Codable, Equatable, Sendable {
    public let id: String
    public var manifestSHA256: String?
    public var released = false
    public init() { id = UUID().uuidString.lowercased() }
    public var cacheSuffix: String { "/snapshot/" + id }
}

struct ContentSnapshotFailure: Decodable {
    struct Detail: Decodable { let code: String; let message: String }
    let error: Detail
}
public struct ContentSnapshotError: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    var invalidatesCache: Bool { ["SNAPSHOT_EXPIRED", "ARTIFACT_MISSING", "REQUEST_CONFLICT", "SOURCE_REVOKED", "REVISION_MISMATCH"].contains(code) }
}

struct ContentSnapshotPage: Decodable, Sendable {
    struct Entry: Decodable, Equatable, Sendable {
        let path: String
        let directory: Bool
        let size: UInt64?
        let modified: Double?
        let artifact: String?
        let sha256: String?
    }
    let id: String
    let sourceID: String
    let revision: String
    let state: String
    let bytes: UInt64
    let files: Int
    let remainingSeconds: Int
    let manifestSHA256: String
    let code: String
    let message: String
    let entries: [Entry]?
    let offset: Int?
    let totalEntries: Int?
    func validate(source: CompanionContentSource, reference: ContentSnapshotReference) throws {
        guard id == reference.id, sourceID == source.id, revision == source.revision,
              ["preparing", "ready", "failed"].contains(state), remainingSeconds >= 0, remainingSeconds <= 86_400,
              bytes <= 1_073_741_824, files >= 0, files <= 20_000 else { throw ToolboxError.invalidResponse("快照响应身份或范围无效") }
        if state == "failed" { throw ContentSnapshotError(code: code, message: message.isEmpty ? "快照准备失败，请创建新的任务" : message) }
        if state == "ready" {
            guard Self.validHash(manifestSHA256), reference.manifestSHA256 == nil || reference.manifestSHA256 == manifestSHA256 else {
                throw ContentSnapshotError(code: "REQUEST_CONFLICT", message: "快照清单已改变，停止使用旧缓存")
            }
        }
    }
    static func validHash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

extension CompanionContentDevice {
    public func prepareSnapshot(_ reference: ContentSnapshotReference, source origin: ContentSource,
                                item: ExportContentItem, progress: ProgressUpdate?) async throws -> CompanionSnapshotDevice {
        guard supportsSnapshots, !reference.released else { throw ContentSnapshotError(code: "SNAPSHOT_EXPIRED", message: "快照不可继续，请创建新的导出任务") }
        for component in origin.path + item.path { try ContentReader.validateComponent(component) }
        let index = origin.kind == .notes ? (origin.path + [".database", "HvNote.db"]).joined(separator: "/") : ""
        let query = [("requestID", reference.id), ("sourceID", source.id), ("revision", source.revision),
                     ("path", (origin.path + item.path).joined(separator: "/")), ("directory", item.isDirectory ? "true" : "false"),
                     ("index", index), ("indexSHA256", origin.revision ?? "")]
        let initial = try JSONDecoder().decode(ContentSnapshotPage.self, from: await wire.send("POST", "snapshots", query, nil))
        try initial.validate(source: source, reference: reference)
        var pages: [ContentSnapshotPage.Entry] = []
        var page = initial
        var readyHash: String?
        while true {
            try Task.checkCancellation()
            let offset = pages.count
            let data = try await wire.send("GET", "snapshots/status", [("snapshotID", reference.id), ("offset", String(offset))], nil)
            page = try JSONDecoder().decode(ContentSnapshotPage.self, from: data)
            try page.validate(source: source, reference: reference)
            if page.state == "ready" {
                if let readyHash, readyHash != page.manifestSHA256 { throw ToolboxError.invalidResponse("快照分页版本不一致") }
                readyHash = page.manifestSHA256
                guard let rows = page.entries, let total = page.totalEntries, page.offset == offset,
                      total >= 0, total <= 20_000, rows.count <= 200, offset + rows.count <= total,
                      !rows.isEmpty || total == offset else { throw ToolboxError.invalidResponse("快照清单分页无效") }
                pages += rows
                if pages.count == total { break }
            } else {
                progress?(.init(completed: page.bytes, total: nil))
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        return try CompanionSnapshotDevice(parent: self, reference: reference, hash: page.manifestSHA256, entries: pages)
    }
    func discardSnapshotCache(_ reference: ContentSnapshotReference, transferID: UUID) {
        ResumableTransfers.discard(scope: deviceID + "/" + source.cacheIdentity + reference.cacheSuffix,
                                  id: transferID, base: cacheBase)
    }
    public func releaseSnapshot(_ reference: ContentSnapshotReference) async throws {
        _ = try await wire.send("POST", "snapshots/release", [("snapshotID", reference.id)], nil)
    }
}

/// A manifest-backed tree: byte requests only target immutable artifact IDs, never live source paths.
public final class CompanionSnapshotDevice: DeviceConnection, Sendable {
    public let kind = ConnectionKind.companion
    public let reference: ContentSnapshotReference
    private let parent: CompanionContentDevice
    private let entries: [ContentSnapshotPage.Entry]
    private var scope: String { parent.deviceID + "/" + parent.source.cacheIdentity + reference.cacheSuffix }
    init(parent: CompanionContentDevice, reference: ContentSnapshotReference, hash: String, entries: [ContentSnapshotPage.Entry]) throws {
        self.parent = parent
        var reference = reference; reference.manifestSHA256 = hash; self.reference = reference
        var names = Set<String>(), artifacts = Set<String>()
        var total: UInt64 = 0
        for entry in entries {
            let path = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.isEmpty, path.count <= 64 else { throw ToolboxError.invalidResponse("快照资源路径无效") }
            for name in path { try ContentReader.validateComponent(name) }
            guard names.insert(path.map(DirectorySync.nameKey).joined(separator: "/")).inserted else { throw ToolboxError.invalidResponse("快照资源重名") }
            if entry.directory {
                guard entry.artifact == nil, entry.sha256 == nil else { throw ToolboxError.invalidResponse("快照目录含文件内容") }
            } else {
                guard let artifact = entry.artifact, CompanionContentSource.validID(artifact), artifacts.insert(artifact).inserted,
                      let sha = entry.sha256, ContentSnapshotPage.validHash(sha), let size = entry.size,
                      size <= 1_073_741_824 - total else { throw ToolboxError.invalidResponse("快照资源无效或超过限额") }
                total += size
            }
        }
        let folders = Set(entries.filter(\.directory).map(\.path))
        for entry in entries {
            let components = entry.path.split(separator: "/")
            for count in 1..<components.count {
                guard folders.contains(components.prefix(count).joined(separator: "/")) else { throw ToolboxError.invalidResponse("快照缺少父目录") }
            }
        }
        self.entries = entries
    }
    private func check() async throws {
        let data = try await parent.wire.send("POST", "snapshots/lease", [("snapshotID", reference.id), ("offset", "0")], nil)
        let status = try JSONDecoder().decode(ContentSnapshotPage.self, from: data)
        try status.validate(source: parent.source, reference: reference)
        guard status.state == "ready" else { throw ToolboxError.invalidResponse("快照未就绪") }
    }
    public func info() async throws -> DeviceInfo { try await check(); return try await parent.info() }
    public func list(_ folder: DeviceFolder) async throws -> [DeviceItem] {
        guard case let .companion(path) = folder else { throw ToolboxError.message("快照目录无效") }
        guard path.isEmpty || entries.contains(where: { $0.path == path && $0.directory }) else { throw ToolboxError.message("目录不属于本次快照") }
        try await check()
        return entries.filter { $0.path.split(separator: "/").dropLast().joined(separator: "/") == path }.map { entry in
            .init(id: .companion(path: entry.path), name: String(entry.path.split(separator: "/").last!),
                  folder: entry.directory ? .companion(path: entry.path) : nil, size: entry.size,
                  modified: entry.modified.map { Date(timeIntervalSince1970: $0 / 1000) })
        }.sorted(by: listOrder)
    }
    func expectedHash(for item: DeviceItem) throws -> String {
        guard case let .companion(path) = item.id,
              let hash = entries.first(where: { $0.path == path && !$0.directory })?.sha256 else {
            throw ToolboxError.invalidResponse("文件不属于当前快照")
        }
        return hash
    }
    private var resumeWire: ResumeWire {
        .init(send: { [self] method, route, query, body in
            guard body == nil else { throw ToolboxError.unsupported("快照仅支持读取") }
            if route == "resume/abort" { return Data("{}".utf8) } // There is no remote per-transfer receipt to delete.
            guard let path = query.first(where: { $0.0 == "path" })?.1,
                  let entry = entries.first(where: { $0.path == path && !$0.directory }), let artifact = entry.artifact else {
                throw ToolboxError.invalidResponse("下载资源不属于本次快照")
            }
            var params = [("snapshotID", reference.id), ("artifactID", artifact)]
            if route == "resume/download/chunk" {
                params += query.filter { ["offset", "count"].contains($0.0) }
                return try await parent.wire.send("GET", "snapshots/artifact/chunk", params, nil)
            }
            guard route == "resume/download/info", method == "GET" else { throw ToolboxError.unsupported("快照仅支持读取") }
            let data = try await parent.wire.send("GET", "snapshots/artifact/info", params, nil)
            let actual = try JSONDecoder().decode(ContentSnapshotPage.Entry.self, from: data)
            guard actual == entry else { throw ContentSnapshotError(code: "REQUEST_CONFLICT", message: "快照资源描述已改变") }
            struct Info: Encodable { let size: UInt64; let sha256: String }
            return try JSONEncoder().encode(Info(size: entry.size!, sha256: entry.sha256!))
        })
    }
    public func downloadResumable(_ item: DeviceItem, to file: URL, transferID: UUID, progress: ProgressUpdate?) async throws {
        guard case let .companion(path) = item.id, !item.isFolder else { throw ToolboxError.message("请选择快照文件") }
        // ResumeWire chunks do not carry the source path; bind it to this artifact for the whole transfer.
        let wire = ResumeWire(send: { [self] method, route, query, body in
            try await resumeWire.send(method, route, query.filter { $0.0 != "path" } + [("path", path)], body)
        })
        try await ResumableTransfers.download(path: path, destination: file, scope: scope,
            id: transferID, wire: wire, progress: progress, base: parent.cacheBase)
    }
    public func download(_ item: DeviceItem, to file: URL, progress: ProgressUpdate?) async throws {
        let id = UUID()
        defer { ResumableTransfers.discard(scope: scope, id: id, base: parent.cacheBase) }
        try await downloadResumable(item, to: file, transferID: id, progress: progress)
    }
    public func discardResumable(_ id: UUID) async throws { ResumableTransfers.discard(scope: scope, id: id, base: parent.cacheBase) }
    public func upload(_ file: URL, to folder: DeviceFolder, progress: ProgressUpdate?) async throws { throw ToolboxError.unsupported("快照仅支持读取") }
    public func requestAPKInstall(_ apk: URL, progress: ProgressUpdate?) async throws { throw ToolboxError.unsupported("快照不能安装应用") }
    public func close() async {}
}
