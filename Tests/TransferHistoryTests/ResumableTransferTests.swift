import CryptoKit
import Foundation
import Testing
@testable import ToolboxCore

struct ResumableTransferTests {
    @Test(arguments: [0, 1, ResumableTransfers.chunkSize, ResumableTransfers.chunkSize + 1])
    func handlesEmptyFilesAndChunkBoundaries(count: Int) async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data(repeating: 5, count: count), source = folder.appending(path: "source.bin")
        try bytes.write(to: source)
        let upload = ResumeTestServer(payload: bytes)
        try await ResumableTransfers.upload(source, path: "", id: UUID(), wire: upload.wire, progress: nil)
        #expect(await upload.received == bytes)
        let download = ResumeTestServer(payload: bytes), target = folder.appending(path: "target.bin")
        try await ResumableTransfers.download(path: "file.bin", destination: target, scope: "d/r", id: UUID(),
                                              wire: download.wire, progress: nil, base: folder.appending(path: "cache"))
        #expect(try Data(contentsOf: target) == bytes)
    }
    private func fixture() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
    private func patterned(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 + $0 / 257) % 251) })
    }
    @Test func uploadResumesFromPartiallyReceivedChunkAndRecognizesLostCommitReply() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "file.bin")
        let bytes = patterned(3 * ResumableTransfers.chunkSize + 71)
        try bytes.write(to: source)
        let server = ResumeTestServer(payload: bytes, failAt: UInt64(ResumableTransfers.chunkSize), loseCommit: true)
        let id = UUID()
        await #expect(throws: URLError.self) {
            try await ResumableTransfers.upload(source, path: "books", id: id, wire: server.wire, progress: nil)
        }
        let retained = await server.received.count
        #expect(retained == ResumableTransfers.chunkSize + 12345)
        await #expect(throws: URLError.self) {
            try await ResumableTransfers.upload(source, path: "books", id: id, wire: server.wire, progress: nil)
        }
        let chunks = await server.uploadOffsets
        #expect(chunks.contains(UInt64(retained)))
        #expect(await server.received == bytes)
        try await ResumableTransfers.upload(source, path: "books", id: id, wire: server.wire, progress: nil)
        #expect(await server.uploadOffsets == chunks)
    }
    @Test func uploadRejectsChangedSourceForExistingTransfer() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "file.bin"), id = UUID()
        try Data(repeating: 1, count: 2 * ResumableTransfers.chunkSize).write(to: source)
        let server = ResumeTestServer(payload: Data(), failAt: 0)
        await #expect(throws: URLError.self) { try await ResumableTransfers.upload(source, path: "", id: id, wire: server.wire, progress: nil) }
        try Data(repeating: 2, count: 2 * ResumableTransfers.chunkSize).write(to: source)
        await #expect(throws: ToolboxError.self) { try await ResumableTransfers.upload(source, path: "", id: id, wire: server.wire, progress: nil) }
        #expect(await server.committed == false)
    }
    @Test func downloadResumesAcrossClientRecreationAndVerifiesFullContent() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = patterned(3 * ResumableTransfers.chunkSize + 29)
        let server = ResumeTestServer(payload: bytes, failAt: UInt64(ResumableTransfers.chunkSize))
        let id = UUID(), target = folder.appending(path: "download.bin"), cache = folder.appending(path: "cache")
        await #expect(throws: URLError.self) {
            try await ResumableTransfers.download(path: "file.bin", destination: target, scope: "device/root", id: id, wire: server.wire, progress: nil, base: cache)
        }
        let part = ResumableTransfers.cache(scope: "device/root", id: id, base: cache).appending(path: "data")
        #expect(try Data(contentsOf: part).count == ResumableTransfers.chunkSize)
        let before = await server.downloadOffsets.count
        try await ResumableTransfers.download(path: "file.bin", destination: target, scope: "device/root", id: id, wire: server.wire, progress: nil, base: cache)
        #expect(await server.downloadOffsets[before] == UInt64(ResumableTransfers.chunkSize))
        #expect(try Data(contentsOf: target) == bytes)
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }
    @Test func downloadRejectsChangedSourceAndDoesNotOverwriteDestination() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data(repeating: 3, count: 2 * ResumableTransfers.chunkSize)
        let server = ResumeTestServer(payload: bytes, failAt: UInt64(ResumableTransfers.chunkSize))
        let id = UUID(), target = folder.appending(path: "file.bin"), cache = folder.appending(path: "cache")
        await #expect(throws: URLError.self) { try await ResumableTransfers.download(path: "file.bin", destination: target, scope: "d/r", id: id, wire: server.wire, progress: nil, base: cache) }
        await server.replacePayload(Data(repeating: 4, count: bytes.count))
        await #expect(throws: ToolboxError.self) { try await ResumableTransfers.download(path: "file.bin", destination: target, scope: "d/r", id: id, wire: server.wire, progress: nil, base: cache) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try Data("existing file".utf8).write(to: target)
        await #expect(throws: ToolboxError.self) { try await ResumableTransfers.download(path: "file.bin", destination: target, scope: "other/root", id: UUID(), wire: server.wire, progress: nil, base: cache) }
        #expect(try Data(contentsOf: target) == Data("existing file".utf8))
        ResumableTransfers.discard(scope: "d/r", id: id, base: cache)
        #expect(!FileManager.default.fileExists(atPath: ResumableTransfers.cache(scope: "d/r", id: id, base: cache).appending(path: "data").path))
    }
    @Test func downloadDoesNotPublishCorruptedChunks() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let server = ResumeTestServer(payload: Data(repeating: 3, count: 2048), corrupt: true)
        let target = folder.appending(path: "file.bin")
        await #expect(throws: ToolboxError.self) { try await ResumableTransfers.download(path: "file.bin", destination: target, scope: "d/r", id: UUID(), wire: server.wire, progress: nil, base: folder.appending(path: "cache")) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
    @Test func downloadRecognizesAlreadyPublishedOwnedFile() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("already published".utf8), id = UUID(), scope = "d/r"
        let target = folder.appending(path: "file.bin"), cache = folder.appending(path: "cache")
        try bytes.write(to: target)
        let part = ResumableTransfers.cache(scope: scope, id: id, base: cache)
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        let receipt = ResumableTransfers.Receipt(scope: scope, path: "file.bin", destination: target, size: UInt64(bytes.count),
                                                sha256: ResumableTransfers.hex(Data(SHA256.hash(data: bytes))), publishing: true)
        try JSONEncoder().encode(receipt).write(to: part.appending(path: "record.json"))
        let server = ResumeTestServer(payload: bytes)
        try await ResumableTransfers.download(path: "file.bin", destination: target, scope: scope, id: id, wire: server.wire, progress: nil, base: cache)
        #expect(await server.downloadOffsets.isEmpty)
        #expect(try Data(contentsOf: target) == bytes)
    }
}

private actor ResumeTestServer {
    var payload: Data
    var received = Data()
    var uploadOffsets: [UInt64] = []
    var downloadOffsets: [UInt64] = []
    var committed = false
    private let failAt: UInt64?
    private let loseCommit: Bool
    private let corrupt: Bool
    private var failed = false
    private var lost = false
    private var descriptor: [String:String]?
    nonisolated var wire: ResumeWire { .init(send: { method, path, query, body in try await self.request(path, query: query, body: body) }) }
    init(payload: Data, failAt: UInt64? = nil, loseCommit: Bool = false, corrupt: Bool = false) {
        self.payload = payload; self.failAt = failAt; self.loseCommit = loseCommit; self.corrupt = corrupt
    }
    func replacePayload(_ data: Data) { payload = data }
    private func status() throws -> Data { try JSONEncoder().encode(ResumableTransfers.UploadStatus(offset: UInt64(received.count), completed: committed)) }
    func request(_ route: String, query: [(String,String)], body: Data?) throws -> Data {
        let q = Dictionary(uniqueKeysWithValues: query)
        switch route {
        case "resume/upload/status":
            if let descriptor, descriptor != q { throw ToolboxError.message("changed") }
            descriptor = q; return try status()
        case "resume/upload/chunk":
            let offset = UInt64(q["offset"]!)!, body = body!
            uploadOffsets.append(offset)
            guard offset == received.count else { throw ToolboxError.message("offset") }
            if failAt == offset && !failed {
                received.append(body.prefix(12345)); failed = true; throw URLError(.networkConnectionLost)
            }
            received.append(body); return try status()
        case "resume/upload/commit":
            guard ResumableTransfers.hex(Data(SHA256.hash(data: received))) == descriptor?["sha256"] else { throw ToolboxError.message("SHA") }
            committed = true
            if loseCommit && !lost { lost = true; throw URLError(.networkConnectionLost) }
            return try status()
        case "resume/download/info":
            return try JSONEncoder().encode(ResumableTransfers.DownloadInfo(size: UInt64(payload.count), sha256: ResumableTransfers.hex(Data(SHA256.hash(data: payload)))))
        case "resume/download/chunk":
            let offset = UInt64(q["offset"]!)!, count = Int(q["count"]!)!
            downloadOffsets.append(offset)
            if failAt == offset && !failed { failed = true; throw URLError(.networkConnectionLost) }
            var bytes = payload.subdata(in: Int(offset)..<(Int(offset)+count))
            if corrupt && !bytes.isEmpty { bytes[0] ^= 1 }
            return bytes
        case "resume/abort": return Data("{}".utf8)
        default: throw ToolboxError.message("unknown route")
        }
    }
}
