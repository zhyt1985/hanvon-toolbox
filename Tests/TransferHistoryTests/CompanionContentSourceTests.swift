import CryptoKit
import Foundation
import Testing
@testable import ToolboxCore

struct CompanionContentSourceTests {
    static let id = "11111111-2222-4333-8444-555555555555"
    static let revision = "11111111-2222-4333-8444-555555555556"
    static let newRevision = "11111111-2222-4333-8444-555555555557"
    var source: CompanionContentSource {
        .init(id: Self.id, revision: Self.revision, name: "合成来源", kind: .files, authorized: true, readable: true)
    }
    private func temp() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "ContentSourceTests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func virtualSourceNeverForwardsMutationCalls() async throws {
        let server = SourceTestWire(source: source, bytes: Data([1]))
        let device = try CompanionContentDevice(source: source, deviceID: "identity", wire: server.wire)
        let info = try await device.info()
        #expect(!info.canManageFiles && !info.supportsAPK && info.volumes[0].identity == source.cacheIdentity)
        let folder = DeviceFolder.companion(path: "")
        let item = DeviceItem(id: .companion(path: "file"), name: "file", folder: nil, size: 1)
        await #expect(throws: (any Error).self) { try await device.makeFolder(named: "bad", in: folder) }
        await #expect(throws: (any Error).self) { try await device.rename(item, in: folder, to: "bad") }
        await #expect(throws: (any Error).self) { try await device.delete(item) }
        await #expect(throws: (any Error).self) { try await device.relocate(item, to: folder, copying: true) }
        await #expect(throws: (any Error).self) { try await device.upload(URL(fileURLWithPath: "/no-file"), to: folder, progress: nil) }
        await #expect(throws: (any Error).self) { try await device.requestAPKInstall(URL(fileURLWithPath: "/no-file"), progress: nil) }
        #expect(await server.routes() == ["sources"])
    }

    @Test func sourceAndRevisionAreAttachedToEveryReadAndTraversalIsRejected() async throws {
        let server = SourceTestWire(source: source, bytes: Data([1]))
        let device = try CompanionContentDevice(source: source, deviceID: "identity", wire: server.wire)
        #expect(try await device.list(.companion(path: "")).first?.name == "file")
        await #expect(throws: (any Error).self) { try await device.list(.companion(path: "../other")) }
        await #expect(throws: (any Error).self) { try await device.list(.companion(path: "/outside")) }
        #expect(await server.routes() == ["list"])
    }

    @Test func downloadUsesScopedResumeAndVerifiesBytes() async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data((0..<1_048_579).map { UInt8($0 % 251) })
        let server = SourceTestWire(source: source, bytes: bytes)
        let device = try CompanionContentDevice(source: source, deviceID: "identity", wire: server.wire, cacheBase: base.appending(path: "cache"))
        let item = try #require(try await device.list(.companion(path: "")).first)
        let output = base.appending(path: "download")
        try await device.download(item, to: output, progress: nil)
        #expect(try Data(contentsOf: output) == bytes)
        #expect(await server.routes().contains("resume/abort"))
    }

    @Test(arguments: [false, true]) func revokedGrantDuringDownloadClearsUnpublishedParts(pairingRevocation: Bool) async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let cache = base.appending(path: "cache")
        let server = SourceTestWire(source: source, bytes: Data(repeating: 4, count: 3 * 1024 * 1024), revokeAfterChunk: true,
                                    pairingRevocation: pairingRevocation)
        let device = try CompanionContentDevice(source: source, deviceID: "identity", wire: server.wire, cacheBase: cache)
        let origin = ContentSource(connection: .companion, deviceScope: source.binding(deviceID: "identity"), path: [], kind: .files,
                                   displayName: "test", resumeIdentity: "identity", resumeVolume: source.cacheIdentity, wirelessSource: source)
        let catalog = try await ContentReader.scan(origin, root: .companion(path: ""), device: device)
        let job = ContentExportJob(source: origin, items: catalog.items, parent: base)
        let result = try await ContentExporter.run(job, root: .companion(path: ""), device: device,
            store: ContentExportStore(directory: base.appending(path: "jobs"))) { _ in }
        #expect(result.rows.first?.state == .failed)
        #expect(!FileManager.default.fileExists(atPath: job.output.appending(path: ".pending-" + job.rows[0].id.uuidString).path))
        for directory in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "data").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "record.json").path))
        }
    }

    @Test func changedRevisionCannotUseOldDeviceAndCacheScopesDiffer() async throws {
        let server = SourceTestWire(source: source, bytes: Data([1]))
        let device = try CompanionContentDevice(source: source, deviceID: "identity", wire: server.wire)
        await server.changeRevision()
        await #expect(throws: ContentSourceAccessError.changed) { try await device.info() }
        await #expect(throws: ContentSourceAccessError.denied) { try await device.list(.companion(path: "")) }
        let changed = CompanionContentSource(id: source.id, revision: Self.newRevision, name: source.name, kind: .files, authorized: true, readable: true)
        #expect(source.cacheIdentity != changed.cacheIdentity)
        #expect(source.binding(deviceID: "synthetic-device-A") != source.binding(deviceID: "synthetic-device-B"))
    }

    @Test func unauthorizedAndMalformedDescriptorsAreRejected() throws {
        let server = SourceTestWire(source: source, bytes: Data())
        let denied = CompanionContentSource(id: source.id, revision: source.revision, name: "unknown", kind: .notes, authorized: false, readable: true)
        #expect(throws: ContentSourceAccessError.denied) { try CompanionContentDevice(source: denied, deviceID: "identity", wire: server.wire) }
        let bad = CompanionContentSource(id: "../escape", revision: source.revision, name: "bad", kind: .files, authorized: true, readable: true)
        #expect(throws: (any Error).self) { try bad.validate() }
    }

    @Test func accessResponsesAreBoundToSourceAndContainOnlyKnownStates() throws {
        let id = UUID().uuidString.lowercased()
        let valid = Data("{\"id\":\"\(id)\",\"sourceID\":\"\(source.id)\",\"code\":\"123456\",\"state\":\"approved\"}".utf8)
        #expect(try CompanionContentAccessRequest.decode(valid, sourceID: source.id).state == "approved")
        #expect(throws: (any Error).self) { try CompanionContentAccessRequest.decode(valid, sourceID: "another") }
        let invalid = Data("{\"id\":\"\(id)\",\"sourceID\":\"\(source.id)\",\"code\":\"abc123\",\"state\":\"granted\"}".utf8)
        #expect(throws: (any Error).self) { try CompanionContentAccessRequest.decode(invalid, sourceID: source.id) }
    }

    @Test func oldContentHistoryWithoutDedicatedSourceStillDecodes() throws {
        let old = ContentSource(connection: .usb, deviceScope: "old", path: ["notes"], kind: .notes, displayName: "old notes")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "wirelessSource")
        let decoded = try JSONDecoder().decode(ContentSource.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.wirelessSource == nil && decoded.id == old.id)
    }
}

private actor SourceTestWire {
    let source: CompanionContentSource
    let bytes: Data
    let revokeAfterChunk: Bool
    let pairingRevocation: Bool
    var authorized = true
    var revision: String
    var calls: [String] = []
    init(source: CompanionContentSource, bytes: Data, revokeAfterChunk: Bool = false, pairingRevocation: Bool = false) {
        self.source = source; self.bytes = bytes; self.revokeAfterChunk = revokeAfterChunk; revision = source.revision
        self.pairingRevocation = pairingRevocation
    }
    nonisolated var wire: ResumeWire {
        .init(send: { [self] method, route, query, body in try await send(method, route, query, body) })
    }
    func routes() -> [String] { calls }
    func changeRevision() { revision = CompanionContentSourceTests.newRevision }
    func send(_ method: String, _ route: String, _ query: [(String,String)], _ body: Data?) throws -> Data {
        calls.append(route)
        #expect(body == nil)
        if route == "sources" {
            return try JSONEncoder().encode([CompanionContentSource(id: source.id, revision: revision, name: source.name,
                kind: source.kind, authorized: authorized, readable: true)])
        }
        let values = Dictionary(uniqueKeysWithValues: query)
        #expect(values["sourceID"] == source.id)
        guard values["revision"] == revision, authorized else {
            if pairingRevocation { throw ToolboxError.pairingExpired }
            throw ContentSourceAccessError.denied
        }
        switch route {
        case "list":
            #expect(method == "GET")
            return try JSONSerialization.data(withJSONObject: [["name":"file","directory":false,"size":bytes.count]])
        case "resume/download/info":
            #expect(method == "GET")
            return try JSONEncoder().encode(ResumableTransfers.DownloadInfo(size: UInt64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined()))
        case "resume/download/chunk":
            let offset = Int(values["offset"]!)!, count = Int(values["count"]!)!
            if revokeAfterChunk { authorized = false }
            return bytes.subdata(in: offset..<offset+count)
        case "resume/abort":
            #expect(method == "POST")
            return Data("{}".utf8)
        default:
            Issue.record("Unexpected route"); throw ToolboxError.unsupported("test")
        }
    }
}
