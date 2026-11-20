import CSQLite
import Foundation
import Testing
@testable import ToolboxCore

struct ContentExportTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ContentTests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func database(in base: URL, sql: String) throws -> URL {
        let url = base.appending(path: UUID().uuidString + ".db")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }
    private var source: ContentSource { .init(connection: .usb, deviceScope: "test-device", path: [], kind: .files, displayName: "test") }
    private var root: DeviceFolder { .companion(path: "") }

    @Test func catalogReadsOnlyKnownOrdinarySchemaAndKeepsUnknownTypes() throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let db = try database(in: base, sql: """
            CREATE TABLE NoteList(name TEXT,nameUser TEXT,noteType INTEGER,hasPsd INTEGER);
            INSERT INTO NoteList VALUES('20261119000001','测试笔记',98,0);
            INSERT INTO NoteList VALUES('20261119000002','',1,1);
            """)
        let records = try HanvonNoteCatalog.read(db)
        #expect(records.count == 2)
        #expect(records[0].title == "测试笔记")
        #expect(records[0].type == 98)
        #expect(!records[0].protected)
        #expect(records[1].title == "未命名笔记")
        #expect(records[1].protected)
    }

    @Test(arguments: [
        "CREATE VIEW NoteList AS SELECT 'key' AS name,'title' AS nameUser;",
        "CREATE TABLE NoteList(nameUser TEXT);",
        "CREATE TABLE NoteList(name TEXT,nameUser TEXT); INSERT INTO NoteList VALUES('../escape','title');",
        "CREATE TABLE NoteList(name TEXT,nameUser TEXT); INSERT INTO NoteList VALUES('dup','one'),('dup','two');"
    ])
    func rejectsUnknownOrUnsafeCatalog(sql: String) throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let db = try database(in: base, sql: sql)
        #expect(throws: (any Error).self) { try HanvonNoteCatalog.read(db) }
    }

    @Test func unknownProtectionIsNotTreatedAsPermission() throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let db = try database(in: base, sql: "CREATE TABLE NoteList(name TEXT,nameUser TEXT); INSERT INTO NoteList VALUES('safe','title');")
        #expect(try HanvonNoteCatalog.read(db).first?.protected == true)
    }

    @Test func indexScanDoesNotDownloadBodiesAndPreservesUnindexedDirectories() async throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let db = try database(in: base, sql: "CREATE TABLE NoteList(name TEXT,nameUser TEXT,noteType INTEGER,hasPsd INTEGER); INSERT INTO NoteList VALUES('20261119000001','测试',1,0);")
        let device = ContentReadTestDevice(files: [".database/HvNote.db": try Data(contentsOf: db),
            "20261119000001/page.psl": Data([1]), "unindexed/page.psl": Data([2])])
        let noteSource = ContentSource(connection: .usb, deviceScope: "test", path: [], kind: .notes, displayName: "notes")
        let catalog = try await ContentReader.scan(noteSource, root: root, device: device)
        #expect(catalog.items.count == 2)
        #expect(catalog.source.revision?.count == 64)
        #expect(catalog.items.first { $0.id == "20261119000001" }?.title == "测试")
        #expect(catalog.items.first { $0.id == "unindexed" }?.indexed == false)
        #expect(await device.readCount("20261119000001/page.psl") == 0)
    }

    @Test func damagedJobDoesNotHideOtherHistory() async throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appending(path: "jobs")
        let store = ContentExportStore(directory: directory)
        let job = ContentExportJob(source: source, items: [], parent: base)
        try await store.save(job)
        try Data("broken".utf8).write(to: directory.appending(path: UUID().uuidString + ".json"))
        let result = try await store.loadReport()
        #expect(result.jobs.map(\.id) == [job.id])
        #expect(result.warning != nil)
    }

    @Test func sourceIdentityIsBoundToTransportAndLocation() {
        let a = source
        let b = ContentSource(connection: .companion, deviceScope: a.deviceScope, path: [], kind: .files, displayName: "test")
        let c = ContentSource(connection: .usb, deviceScope: a.deviceScope, path: ["elsewhere"], kind: .files, displayName: "test")
        #expect(a.id != b.id); #expect(a.id != c.id)
        let row = ContentExportRow(item: .init(id: "a", title: String(repeating: "🧑🏽‍💻", count: 100), path: ["a"], isDirectory: false))
        #expect(row.outputName.utf8.count < 255)
        try? ContentReader.validateComponent(row.outputName)
    }

    @Test func exportsHiddenResourcesAndEmptyDirectoriesWithoutSourceWrites() async throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let device = ContentReadTestDevice(files: ["library/.database/index": Data("index".utf8), "library/page": Data("page".utf8)],
                                           directories: ["library", "library/empty"])
        let item = ExportContentItem(id: "library", title: "库", path: ["library"], isDirectory: true)
        let store = ContentExportStore(directory: base.appending(path: "jobs"))
        let job = ContentExportJob(source: source, items: [item], parent: base)
        let done = try await ContentExporter.run(job, root: root, device: device, store: store) { _ in }
        #expect(done.rows[0].state == .completed, "\(done.rows[0].message ?? "none")")
        let exported = done.output.appending(path: done.rows[0].outputName)
        #expect(try Data(contentsOf: exported.appending(path: "raw/.database/index")) == Data("index".utf8))
        #expect(FileManager.default.fileExists(atPath: exported.appending(path: "raw/empty").path))
        #expect(done.rows[0].resources?.allSatisfy { $0.sha256?.count == 64 && $0.downloaded } == true)
        #expect(try await store.load().first?.rows[0].state == .completed)
    }

    @Test func detectsSameSizeSourceChangesAndDoesNotPublish() async throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let device = ContentReadTestDevice(files: ["file": Data("AAAA".utf8)], mutateAfterRead: true)
        let job = ContentExportJob(source: source, items: [.init(id: "file", title: "file", path: ["file"], isDirectory: false)], parent: base)
        let done = try await ContentExporter.run(job, root: root, device: device, store: ContentExportStore(directory: base.appending(path: "jobs"))) { _ in }
        #expect(done.rows[0].state == .failed)
        #expect(!FileManager.default.fileExists(atPath: done.output.appending(path: done.rows[0].outputName).path))
    }

    @Test func interruptionReopensAndOnlyPublishesVerifiedFiles() async throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let device = ContentReadTestDevice(files: ["a": Data("one".utf8), "b": Data("two".utf8)], failAtRead: 3)
        let items = [ExportContentItem(id: "a", title: "a", path: ["a"], isDirectory: false),
                     ExportContentItem(id: "b", title: "b", path: ["b"], isDirectory: false)]
        let store = ContentExportStore(directory: base.appending(path: "jobs"))
        let job = ContentExportJob(source: source, items: items, parent: base)
        let interrupted = try await ContentExporter.run(job, root: root, device: device, store: store) { _ in }
        #expect(interrupted.rows[0].state == .completed)
        #expect(interrupted.rows[1].state == .interrupted)
        let reopened = try #require(try await store.load().first)
        let done = try await ContentExporter.run(reopened, root: root, device: device, store: store) { _ in }
        #expect(done.rows.allSatisfy { $0.state == .completed })
        #expect(await device.readCount("a") == 2)
    }

    @Test func refusesUnownedOrSymlinkOutputWithoutOverwriting() async throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let device = ContentReadTestDevice(files: ["a": Data("one".utf8)])
        let job = ContentExportJob(source: source, items: [.init(id: "a", title: "a", path: ["a"], isDirectory: false)], parent: base)
        let outside = base.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: job.output, withDestinationURL: outside)
        await #expect(throws: (any Error).self) {
            try await ContentExporter.run(job, root: root, device: device, store: ContentExportStore(directory: base.appending(path: "jobs"))) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func rejectsCaseCollisionsAndActiveDatabaseJournal() async throws {
        let device = ContentReadTestDevice(files: ["dir/Case": Data(), "dir/case": Data()])
        await #expect(throws: (any Error).self) {
            try await ContentReader.inventory(item: .init(id: "dir", title: "dir", path: ["dir"], isDirectory: true),
                                              source: source, root: root, device: device)
        }
        let busy = ContentReadTestDevice(files: ["db-journal": Data([1])])
        await #expect(throws: (any Error).self) { try await ContentReader.checkTransactions(in: root, device: busy) }
    }

    @Test func cancellationClearsStagingAndPreservesFinishedOutputs() async throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let device = ContentReadTestDevice(files: ["a": Data([1]), "b": Data([2])], failAtRead: 4)
        let job = ContentExportJob(source: source, items: [
            .init(id: "a", title: "a", path: ["a"], isDirectory: false),
            .init(id: "b", title: "b", path: ["b"], isDirectory: false)], parent: base)
        let store = ContentExportStore(directory: base.appending(path: "jobs"))
        let paused = try await ContentExporter.run(job, root: root, device: device, store: store) { _ in }
        let cancelled = try await ContentExporter.cancel(paused, store: store)
        #expect(cancelled.rows[0].state == .completed)
        #expect(cancelled.rows[1].state == .cancelled)
        #expect(FileManager.default.fileExists(atPath: cancelled.output.appending(path: cancelled.rows[0].outputName).path))
        #expect(!FileManager.default.fileExists(atPath: cancelled.output.appending(path: ".pending-" + cancelled.rows[1].id.uuidString).path))
    }

    @Test func authorizationRefreshPurgesPausedBodyAndPreservesPublishedItem() async throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let device = ContentReadTestDevice(files: ["a": Data([1]), "b": Data([2])], failAtRead: 4)
        let job = ContentExportJob(source: source, items: [
            .init(id: "a", title: "a", path: ["a"], isDirectory: false),
            .init(id: "b", title: "b", path: ["b"], isDirectory: false)], parent: base)
        let store = ContentExportStore(directory: base.appending(path: "jobs"))
        let paused = try await ContentExporter.run(job, root: root, device: device, store: store) { _ in }
        let invalidated = try await ContentExporter.invalidateAccess(paused, store: store)
        #expect(invalidated.rows[0].state == .completed)
        #expect(invalidated.rows[1].state == .failed)
        #expect(!invalidated.paused)
        #expect(FileManager.default.fileExists(atPath: invalidated.output.appending(path: invalidated.rows[0].outputName).path))
        #expect(!FileManager.default.fileExists(atPath: invalidated.output.appending(path: ".pending-" + invalidated.rows[1].id.uuidString).path))
    }
}

private actor ContentReadTestDevice: DeviceConnection {
    nonisolated let kind = ConnectionKind.usb
    private var files: [String: Data]
    private let directories: Set<String>
    private let mutate: Bool
    private let failAt: Int?
    private var reads = 0
    private var counts: [String: Int] = [:]
    init(files: [String: Data], directories: Set<String> = [], mutateAfterRead: Bool = false, failAtRead: Int? = nil) {
        self.files = files; self.directories = directories; mutate = mutateAfterRead; failAt = failAtRead
    }
    func info() throws -> DeviceInfo { throw ToolboxError.unsupported("test") }
    func list(_ folder: DeviceFolder) throws -> [DeviceItem] {
        guard case let .companion(path) = folder else { throw ToolboxError.message("folder") }
        let prefix = path.isEmpty ? "" : path + "/"
        var members: [String: Bool] = [:]
        for key in Set(files.keys).union(directories) where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            guard !suffix.isEmpty, let first = suffix.split(separator: "/").first else { continue }
            let name = String(first)
            members[name] = members[name] == true || suffix.contains("/") || directories.contains(prefix + name)
        }
        return members.keys.sorted().map { name in
            let p = prefix + name, directory = members[name]!
            return .init(id: .companion(path: p), name: name, folder: directory ? .companion(path: p) : nil,
                         size: directory ? nil : UInt64(files[p]!.count))
        }
    }
    func download(_ item: DeviceItem, to file: URL, progress: ProgressUpdate?) throws {
        try Task.checkCancellation()
        reads += 1
        if reads == failAt { throw URLError(.networkConnectionLost) }
        guard case let .companion(path) = item.id, let bytes = files[path] else { throw ToolboxError.message("file") }
        counts[path, default: 0] += 1
        try bytes.write(to: file, options: .withoutOverwriting)
        if mutate { files[path] = Data(repeating: 0x42, count: bytes.count) }
    }
    func upload(_ file: URL, to folder: DeviceFolder, progress: ProgressUpdate?) throws { throw ToolboxError.unsupported("read-only test") }
    func requestAPKInstall(_ file: URL, progress: ProgressUpdate?) throws { throw ToolboxError.unsupported("read-only test") }
    func close() {}
    func readCount(_ path: String) -> Int { counts[path, default: 0] }
}
