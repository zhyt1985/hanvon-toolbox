import CryptoKit
import Darwin
import Foundation

struct ResumeWire: Sendable {
    let send: @Sendable (String, String, [(String, String)], Data?) async throws -> Data
}

enum ResumableTransfers {
    static let chunkSize = 1024 * 1024
    struct UploadStatus: Codable { let offset: UInt64; let completed: Bool }
    struct DownloadInfo: Codable { let size: UInt64; let sha256: String }
    struct Receipt: Codable, Equatable {
        let scope: String
        let path: String
        let destination: URL
        let size: UInt64
        let sha256: String
        var publishing = false
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func fingerprint(_ info: DownloadInfo) throws -> DirectorySync.Fingerprint {
        guard info.sha256.utf8.count == 64, info.size <= 4 * 1024 * 1024 * 1024 else {
            throw ToolboxError.invalidResponse("续传文件信息无效")
        }
        let bytes = Array(info.sha256.utf8)
        var hash = Data()
        for i in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[i..<i+2], as: UTF8.self), radix: 16) else {
                throw ToolboxError.invalidResponse("续传文件指纹无效")
            }
            hash.append(byte)
        }
        return .init(byteCount: info.size, sha256: hash)
    }

    static func upload(_ source: URL, path: String, id: UUID, wire: ResumeWire, progress: ProgressUpdate?) async throws {
        try validateFileName(source.lastPathComponent)
        let expected = try DirectorySync.fingerprint(of: source)
        guard expected.byteCount <= 4 * 1024 * 1024 * 1024 else { throw ToolboxError.unsupported("无线续传支持不超过 4 GiB 的单个文件") }
        let query = [("id", id.uuidString), ("path", path), ("name", source.lastPathComponent),
                     ("size", String(expected.byteCount)), ("sha256", hex(expected.sha256))]
        let status = try JSONDecoder().decode(UploadStatus.self, from: await wire.send("GET", "resume/upload/status", query, nil))
        guard status.offset <= expected.byteCount, !status.completed || status.offset == expected.byteCount else {
            throw ToolboxError.invalidResponse("设备续传位置无效")
        }
        progress?(.init(completed: status.offset, total: expected.byteCount, resumedFrom: status.offset > 0 ? status.offset : nil))
        if status.completed { return }
        var offset = status.offset
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try input.seek(toOffset: offset)
        while offset < expected.byteCount {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: Int(min(UInt64(chunkSize), expected.byteCount - offset))), !bytes.isEmpty else {
                throw ToolboxError.message("Mac 源文件已改变，请重新加入任务")
            }
            let reply = try await wire.send("POST", "resume/upload/chunk", [("id", id.uuidString), ("offset", String(offset))], bytes)
            let received = try JSONDecoder().decode(UploadStatus.self, from: reply)
            guard received.offset == offset + UInt64(bytes.count), !received.completed else {
                throw ToolboxError.invalidResponse("设备未确认完整接收当前分块")
            }
            offset = received.offset
            progress?(.init(completed: offset, total: expected.byteCount))
        }
        try Task.checkCancellation()
        guard try DirectorySync.fingerprint(of: source) == expected else { throw ToolboxError.message("Mac 源文件已改变，停止提交") }
        let reply = try await wire.send("POST", "resume/upload/commit", [("id", id.uuidString)], nil)
        let committed = try JSONDecoder().decode(UploadStatus.self, from: reply)
        guard committed.completed, committed.offset == expected.byteCount else { throw ToolboxError.invalidResponse("设备未确认续传文件提交") }
        progress?(.init(completed: expected.byteCount, total: expected.byteCount))
    }

    static func cache(scope: String, id: UUID, base: URL? = nil) -> URL {
        let root = base ?? URL.applicationSupportDirectory.appending(path: "HanvonToolbox/TransferParts")
        return root.appending(path: hex(Data(SHA256.hash(data: Data((scope + "/" + id.uuidString).utf8)))))
    }

    static func download(path: String, destination: URL, scope: String, id: UUID, wire: ResumeWire,
                         progress: ProgressUpdate?, base: URL? = nil) async throws {
        let folder = cache(scope: scope, id: id, base: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(folder.appending(path: "lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ToolboxError.message("无法锁定续传缓存") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ToolboxError.message("该文件正在由另一个传输任务处理") }
        defer { flock(descriptor, LOCK_UN) }
        let journal = folder.appending(path: "record.json"), part = folder.appending(path: "data")
        let existing = FileManager.default.fileExists(atPath: journal.path)
            ? try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: journal)) : nil
        let targetExists = FileManager.default.fileExists(atPath: destination.path)
        guard !targetExists || existing?.publishing == true else { throw ToolboxError.conflict(destination.lastPathComponent) }
        let infoData = try await wire.send("GET", "resume/download/info", [("id", id.uuidString), ("path", path)], nil)
        let info = try JSONDecoder().decode(DownloadInfo.self, from: infoData)
        let expected = try fingerprint(info)
        var receipt = Receipt(scope: scope, path: path, destination: destination, size: info.size, sha256: hex(expected.sha256))
        if var previous = existing {
            previous.publishing = false
            guard previous == receipt else { throw ToolboxError.message("源文件或下载位置已改变，请重新加入任务") }
        }
        if targetExists {
            guard try DirectorySync.fingerprint(of: destination) == expected else { throw ToolboxError.conflict(destination.lastPathComponent) }
            try? FileManager.default.removeItem(at: part); try? FileManager.default.removeItem(at: journal)
            progress?(.init(completed: info.size, total: info.size)); return
        }
        let partFD = open(part.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard partFD >= 0 else { throw ToolboxError.message("无法打开续传缓存") }
        let output = FileHandle(fileDescriptor: partFD, closeOnDealloc: true)
        defer { try? output.close() }
        if existing == nil { try output.truncate(atOffset: 0) }
        try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)
        var offset = try output.seekToEnd()
        guard offset <= info.size else { throw ToolboxError.message("续传缓存大小异常，请取消并重新加入任务") }
        progress?(.init(completed: offset, total: info.size, resumedFrom: offset > 0 ? offset : nil))
        while offset < info.size {
            try Task.checkCancellation()
            let count = min(UInt64(chunkSize), info.size - offset)
            let bytes = try await wire.send("GET", "resume/download/chunk", [("id", id.uuidString), ("offset", String(offset)), ("count", String(count))], nil)
            guard bytes.count == count else { throw ToolboxError.invalidResponse("下载分块长度与请求不符") }
            try output.write(contentsOf: bytes); try output.synchronize()
            offset += count
            progress?(.init(completed: offset, total: info.size))
        }
        try Task.checkCancellation()
        guard try DirectorySync.fingerprint(of: part) == expected else {
            try? FileManager.default.removeItem(at: part); try? FileManager.default.removeItem(at: journal)
            throw ToolboxError.message("下载文件 SHA-256 不匹配，未写入目标；重试将重新下载")
        }
        receipt.publishing = true
        try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)
        let temporary = try createTransferFile(in: destination.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: part, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try? FileManager.default.removeItem(at: part); try? FileManager.default.removeItem(at: journal)
        progress?(.init(completed: info.size, total: info.size))
        _ = try? await wire.send("POST", "resume/abort", [("id", id.uuidString)], nil)
    }

    static func discard(scope: String, id: UUID, base: URL? = nil) {
        let folder = cache(scope: scope, id: id, base: base)
        for name in ["data", "record.json"] { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }
}
