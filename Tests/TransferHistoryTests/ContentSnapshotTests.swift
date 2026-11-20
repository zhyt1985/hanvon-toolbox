import CryptoKit
import Foundation
import Testing
@testable import ToolboxCore

struct ContentSnapshotTests {
    private var source: CompanionContentSource { .init(id: CompanionContentSourceTests.id, revision: CompanionContentSourceTests.revision,
        name: "快照合成来源", kind: .files, authorized: true, readable: true) }
    private func temp() throws -> URL {
        let path = URL.temporaryDirectory.appending(path: "SnapshotTests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    private func setup(_ base: URL, server: SnapshotWire) throws -> (CompanionContentDevice, ContentExportJob, ContentExportStore) {
        let device = try CompanionContentDevice(source: source, deviceID: "snapshot-device", supportsSnapshots: true, wire: server.wire, cacheBase: base.appending(path: "cache"))
        let origin = ContentSource(connection: .companion, deviceScope: source.binding(deviceID: "snapshot-device"), path: [], kind: .files,
            displayName: "合成", resumeIdentity: "snapshot-device", resumeVolume: source.cacheIdentity, wirelessSource: source)
        return (device, ContentExportJob(source: origin, items: [.init(id: "note", title: "合成笔记", path: ["note"], isDirectory: true)], parent: base), ContentExportStore(directory: base.appending(path: "jobs")))
    }
    @Test func snapshotExportNeverDownloadsFromLiveSourceAndReleasesAfterPublish() async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let server = SnapshotWire(source: source)
        let (device, job, store) = try setup(base, server: server)
        let result = try await ContentExporter.run(job, root: .companion(path: ""), device: device, store: store) { _ in }
        #expect(result.rows[0].state == .completed && result.rows[0].snapshot?.released == true)
        let output = result.output.appending(path: result.rows[0].outputName + "/raw/page")
        #expect(try Data(contentsOf: output) == server.bytes)
        #expect(await server.releaseCount == 1)
        #expect(await server.liveReads == 0)
        let manifest = try JSONDecoder().decode(ContentExportManifest.self, from: Data(contentsOf: output.deletingLastPathComponent().deletingLastPathComponent().appending(path: "item.json")))
        #expect(manifest.snapshot?.manifestSHA256 != nil)
        #expect(manifest.capture == "stableReadObserved")
    }
    @Test func pausedSnapshotResumesAcrossDeviceRecreationWithoutPreparingNewBytes() async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let server = SnapshotWire(source: source, stopAfterFirst: true)
        let (device, job, store) = try setup(base, server: server)
        let interrupted = try await ContentExporter.run(job, root: .companion(path: ""), device: device, store: store) { _ in }
        #expect(interrupted.paused && interrupted.rows[0].state == .interrupted)
        let savedID = try #require(interrupted.rows[0].snapshot?.id)
        let resource = try #require(interrupted.rows[0].resources?.first)
        let scope = "snapshot-device/" + source.cacheIdentity + "/snapshot/" + savedID
        let cache = ResumableTransfers.cache(scope: scope, id: resource.id, base: base.appending(path: "cache"))
        #expect(try Data(contentsOf: cache.appending(path: "data")).count == 1_048_576)
        await server.resume()
        let fresh = try CompanionContentDevice(source: source, deviceID: "snapshot-device", supportsSnapshots: true, wire: server.wire, cacheBase: base.appending(path: "cache"))
        let persisted = try #require(try await store.load().first)
        let result = try await ContentExporter.run(persisted, root: .companion(path: ""), device: fresh, store: store) { _ in }
        #expect(result.rows[0].state == .completed && result.rows[0].snapshot?.id == savedID)
        #expect(await server.createdIDs == [savedID])
        #expect(await server.offsets.filter { $0 == 0 }.count == 1)
    }
    @Test(arguments: [false, true]) func expiredOrRevokedSnapshotClearsPartialButKeepsFailure(expired: Bool) async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let server = SnapshotWire(source: source, stopAfterFirst: true)
        let (device, job, store) = try setup(base, server: server)
        let paused = try await ContentExporter.run(job, root: .companion(path: ""), device: device, store: store) { _ in }
        await server.invalidate(expired: expired)
        let result = try await ContentExporter.run(paused, root: .companion(path: ""), device: device, store: store) { _ in }
        #expect(result.rows[0].state == .failed)
        #expect(!FileManager.default.fileExists(atPath: result.output.appending(path: ".pending-" + result.rows[0].id.uuidString).path))
        for cache in (try? FileManager.default.contentsOfDirectory(at: base.appending(path: "cache"), includingPropertiesForKeys: nil)) ?? [] {
            #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "data").path))
        }
    }
    @Test func publishedOutputRecoversAfterReceiptLossEvenWhenSnapshotReleased() async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let server = SnapshotWire(source: source)
        let (device, job, store) = try setup(base, server: server)
        var completed = try await ContentExporter.run(job, root: .companion(path: ""), device: device, store: store) { _ in }
        completed.rows[0].state = .verifying; completed.rows[0].snapshot?.released = false
        await server.invalidate(expired: true)
        let recovered = try await ContentExporter.run(completed, root: .companion(path: ""), device: device, store: store) { _ in }
        #expect(recovered.rows[0].state == .completed)
    }
    @Test func legacyStagedResourceCannotBeMixedWithNewSnapshot() async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let server = SnapshotWire(source: source)
        let (device, initial, store) = try setup(base, server: server)
        let result = try await ContentExporter.run(initial, root: .companion(path: ""), device: device, store: store) { _ in }
        var legacy = result
        let final = legacy.output.appending(path: legacy.rows[0].outputName)
        let stage = legacy.output.appending(path: ".pending-" + legacy.rows[0].id.uuidString)
        try FileManager.default.moveItem(at: final, to: stage)
        let file = stage.appending(path: "raw/page"), old = Data(repeating: 1, count: server.bytes.count)
        try old.write(to: file)
        legacy.rows[0].resources?[0].sha256 = SHA256.hash(data: old).map { String(format: "%02x", $0) }.joined()
        legacy.rows[0].snapshot = nil; legacy.rows[0].state = .interrupted
        let rejected = try await ContentExporter.run(legacy, root: .companion(path: ""), device: device, store: store) { _ in }
        #expect(rejected.rows[0].state == .failed)
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: stage.path))
    }
    @Test func malformedManifestCannotExposeTraversalOrDuplicateArtifacts() throws {
        let server = SnapshotWire(source: source)
        let parent = try CompanionContentDevice(source: source, deviceID: "id", wire: server.wire)
        let entry = ContentSnapshotPage.Entry(path: "../outside", directory: false, size: 1, modified: nil,
            artifact: "11111111-2222-4333-8444-555555555599", sha256: String(repeating: "a", count: 64))
        #expect(throws: (any Error).self) { try CompanionSnapshotDevice(parent: parent, reference: .init(), hash: String(repeating: "b", count: 64), entries: [entry]) }
        let safe = ContentSnapshotPage.Entry(path: "file", directory: false, size: 1, modified: nil, artifact: entry.artifact, sha256: entry.sha256)
        let duplicate = ContentSnapshotPage.Entry(path: "other", directory: false, size: 1, modified: nil, artifact: entry.artifact, sha256: entry.sha256)
        #expect(throws: (any Error).self) { try CompanionSnapshotDevice(parent: parent, reference: .init(), hash: String(repeating: "b", count: 64), entries: [safe, duplicate]) }
    }
}

private actor SnapshotWire {
    nonisolated let bytes = Data(repeating: 0x6b, count: 2_097_155)
    let source: CompanionContentSource
    var snapshotID: String?
    var createdIDs = Set<String>()
    var releaseCount = 0, liveReads = 0
    var offsets: [Int] = []
    var stopAfterFirst: Bool
    var expired = false, revoked = false
    init(source: CompanionContentSource, stopAfterFirst: Bool = false) { self.source = source; self.stopAfterFirst = stopAfterFirst }
    nonisolated var wire: ResumeWire { .init(send: { [self] method, route, query, _ in try await send(method, route, query) }) }
    func resume() { stopAfterFirst = false }
    func invalidate(expired: Bool) { self.expired = expired; revoked = !expired }
    private var artifact: [String: Any] { ["path": "note/page", "directory": false, "size": bytes.count, "modified": 1000,
        "artifact": "11111111-2222-4333-8444-555555555599", "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()] }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    func send(_ method: String, _ route: String, _ params: [(String, String)]) throws -> Data {
        let query = Dictionary(uniqueKeysWithValues: params)
        if revoked { throw ContentSourceAccessError.denied }
        if expired { throw ContentSnapshotError(code: "SNAPSHOT_EXPIRED", message: "快照过期") }
        if route == "snapshots" { snapshotID = query["requestID"]!; createdIDs.insert(snapshotID!) }
        if route == "snapshots" || route == "snapshots/status" || route == "snapshots/lease" {
            let entries: [[String: Any]] = [["path": "note", "directory": true, "modified": 1000], artifact]
            return try json(["id": snapshotID!, "sourceID": source.id, "revision": source.revision, "state": "ready", "bytes": bytes.count,
                "files": 1, "remainingSeconds": 86399, "manifestSHA256": String(repeating: "a", count: 64), "code": "", "message": "",
                "entries": entries, "offset": 0, "totalEntries": 2])
        }
        if route == "snapshots/artifact/info" { return try json(artifact) }
        if route == "snapshots/artifact/chunk" {
            let offset = Int(query["offset"]!)!, count = Int(query["count"]!)!
            if stopAfterFirst && offset > 0 { throw ToolboxError.wirelessUnavailable }
            offsets.append(offset); return bytes.subdata(in: offset..<offset+count)
        }
        if route == "snapshots/release" { releaseCount += 1; return try json(["ok": true]) }
        liveReads += 1; throw ToolboxError.message("不应读取原来源：" + route)
    }
}
