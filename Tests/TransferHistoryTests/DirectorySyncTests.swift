import Foundation
import Testing
import ToolboxCore
@testable import HanvonToolbox

struct DirectorySyncTests {
    @Test(arguments: DirectorySync.Direction.allCases)
    func previewsAndCopiesOnlyMissingItems(direction: DirectorySync.Direction) async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let source = direction == .toDevice ? fixture.mac : fixture.reader
        let destination = direction == .toDevice ? fixture.reader : fixture.mac
        try write("new", to: source.appending(path: "书库/新书.txt"))
        try write("old", to: destination.appending(path: "书库/已有.txt"))
        try write("aaa", to: source.appending(path: "同名.txt"))
        try write("bbb", to: destination.appending(path: "同名.txt"))
        try write("a file", to: destination.appending(path: "类型冲突"))
        try write("skip", to: source.appending(path: "类型冲突/不要复制.txt"))
        try write("source", to: source.appending(path: "NAME.txt"))
        try write("target", to: destination.appending(path: "name.txt"))
        try write("hidden", to: source.appending(path: ".hidden"))
        try FileManager.default.createDirectory(at: source.appending(path: "空目录"), withIntermediateDirectories: false)

        let rows = try await fixture.compare(direction)
        func paths(_ kind: DirectorySync.Row.Kind) -> Set<String> {
            Set(rows.filter { $0.kind == kind }.map(\.path))
        }
        #expect(paths(.copyFile) == ["书库/新书.txt"])
        #expect(paths(.createFolder) == ["空目录"])
        #expect(paths(.keepDestination) == ["书库/已有.txt"])
        #expect(paths(.conflict) == ["同名.txt", "类型冲突", "NAME.txt"])
        #expect(paths(.excluded) == [".hidden"])
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "书库/新书.txt").path))

        let executor = try fixture.executor()
        for step in rows.compactMap(\.step) {
            try await executor.execute(step, progress: nil)
        }
        #expect(try String(contentsOf: destination.appending(path: "书库/新书.txt"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: destination.appending(path: "书库/已有.txt"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: destination.appending(path: "同名.txt"), encoding: .utf8) == "bbb")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appending(path: "空目录").path).isEmpty)
    }

    @Test func rejectsNewConflictsAndChangedSourcesAfterPreview() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let changed = fixture.mac.appending(path: "Changed.txt")
        try write("v1", to: changed)
        try write("planned", to: fixture.mac.appending(path: "Conflict.txt"))
        let rows = try await fixture.compare(.toDevice)
        let stale = try #require(rows.first { $0.path == "Changed.txt" }?.step)
        let conflict = try #require(rows.first { $0.path == "Conflict.txt" }?.step)
        try write("longer v2", to: changed)
        try write("target won the race", to: fixture.reader.appending(path: "conflict.txt"))

        let executor = try fixture.executor()
        await #expect(throws: ToolboxError.self) { try await executor.execute(stale, progress: nil) }
        await #expect(throws: ToolboxError.self) { try await executor.execute(conflict, progress: nil) }
        #expect(!FileManager.default.fileExists(atPath: fixture.reader.appending(path: "Changed.txt").path))
        #expect(try String(contentsOf: fixture.reader.appending(path: "conflict.txt"), encoding: .utf8) == "target won the race")
    }

    @Test(arguments: DirectorySync.Direction.allCases)
    func verifiesOnlySameNameAndSizeAndCleansTemporaryFiles(direction: DirectorySync.Direction) async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let samples = [
            ("书库/一致.txt", "same", "same"),
            ("书库/冲突.txt", "aaa", "bbb"),
            ("书库/大小不同.txt", "short", "longer"),
            ("书库/不可读.txt", "same", "same"),
        ]
        for (path, mac, reader) in samples {
            try write(mac, to: fixture.mac.appending(path: path))
            try write(reader, to: fixture.reader.appending(path: path))
        }
        let audit = SyncDownloadAudit()
        let device = SyncTestDevice(directory: fixture.reader, afterDownload: { name, copy in
            await audit.record(name, at: copy)
            if name == "不可读.txt" { throw CocoaError(.fileReadNoPermission) }
        })
        let root = try DirectorySync.LocalRoot(fixture.mac)
        let quick = try await DirectorySync.compare(direction, local: root, remote: fixture.root, on: device)
        #expect(quick.filter(\.canVerifyContent).count == 3)
        #expect(await audit.copies.isEmpty)

        let verified = try await DirectorySync.compare(direction, local: root, remote: fixture.root,
                                                       on: device, verifyContents: true)
        let matches = verified.filter { $0.kind == .identical }
        #expect(matches.map(\.path) == ["书库/一致.txt"])
        #expect(verified.first { $0.path == "书库/冲突.txt" }?.detail == "内容不同")
        #expect(verified.first { $0.path == "书库/大小不同.txt" }?.detail == "同名文件大小不同")
        #expect(verified.filter(\.canVerifyContent).map(\.path) == ["书库/不可读.txt"])
        #expect(verified.allSatisfy { $0.step == nil })
        let copies = await audit.copies
        #expect(Set(copies.keys) == ["一致.txt", "冲突.txt", "不可读.txt"])
        #expect(copies.values.allSatisfy { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) })
        for (path, mac, reader) in samples {
            #expect(try String(contentsOf: fixture.mac.appending(path: path), encoding: .utf8) == mac)
            #expect(try String(contentsOf: fixture.reader.appending(path: path), encoding: .utf8) == reader)
        }
    }

    @Test func persistedSyncRecordsRejectReplacedLocalRoot() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        try write("planned", to: fixture.mac.appending(path: "Original.txt"))
        try write("MAC", to: fixture.mac.appending(path: "Conflict.txt"))
        try write("N10", to: fixture.reader.appending(path: "Conflict.txt"))
        let rows = try await fixture.compare(.toDevice)
        let target = TransferDestination(connection: .companion, identity: "device", root: fixture.root,
                                         volumeName: "书库", volumeIdentity: "library", launchID: nil)
        let store = TransferHistoryStore(directory: fixture.directory.appending(path: "history"))
        let original = try DirectorySync.LocalRoot(fixture.mac)
        let skipped = rows.compactMap { TransferRecord.Row(syncConflict: $0) }
        #expect(skipped.count == 1)
        let record = TransferRecord(title: "单向同步", target: target, remotePath: [], localFolder: nil,
                                    syncRoot: original, rows: rows.compactMap(\.step).map { .init(step: $0) } + skipped)
        try await store.save(record)
        let restored = try #require(store.load().records.first)
        #expect(restored.syncRoot == original)
        #expect(restored.retryable.map(\.id) == record.retryable.map(\.id))
        #expect(restored.retryable.map(\.name) == ["Original.txt"])
        #expect(restored.summary == "完成 0 · 跳过 1 · 未完成 1")

        try FileManager.default.moveItem(at: fixture.mac, to: fixture.directory.appending(path: "other"))
        try FileManager.default.createDirectory(at: fixture.mac, withIntermediateDirectories: false)
        let executor = TransferExecutor(device: fixture.device, volumeRoot: fixture.root, devicePath: [],
                                        syncRoot: restored.syncRoot)
        let step = try #require(restored.retryable.first)
        await #expect(throws: ToolboxError.self) { try await executor.execute(step, progress: nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.reader.path) == ["Conflict.txt"])
    }

    @Test(arguments: DirectorySync.Direction.allCases)
    func baselineClassifiesLaterChangesAndProtectsMissingPaths(direction: DirectorySync.Direction) async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let initialPaths = ["一致.txt", "Mac.txt", "Device.txt", "Both.txt", "Mac缺失.txt", "已删除目录/样例.txt"]
        for path in initialPaths {
            try write("old", to: fixture.mac.appending(path: path))
            try write("old", to: fixture.reader.appending(path: path))
        }
        let root = try DirectorySync.LocalRoot(fixture.mac)
        let first = try await DirectorySync.compare(direction, local: root, remote: fixture.root, on: fixture.device,
                                                     verifyContents: true)
        let id = UUID()
        let directory = fixture.directory.appending(path: "baselines")
        let saved = try SyncBaselineStore(directory: directory).recordMatches(first, previous: [:], for: id)
        #expect(Set(saved.keys) == Set(initialPaths))
        let reopened = SyncBaselineStore(directory: directory)
        let baseline = try reopened.load(for: id)
        #expect(baseline == saved)
        #expect(try reopened.load(for: UUID()).isEmpty)

        try write("new", to: fixture.mac.appending(path: "Mac.txt"))
        try write("larger", to: fixture.reader.appending(path: "Device.txt"))
        try write("longer", to: fixture.mac.appending(path: "Both.txt"))
        try write("changed!", to: fixture.reader.appending(path: "Both.txt"))
        try write("match again", to: fixture.mac.appending(path: "一致.txt"))
        try write("match again", to: fixture.reader.appending(path: "一致.txt"))
        try FileManager.default.removeItem(at: fixture.mac.appending(path: "Mac缺失.txt"))
        try FileManager.default.removeItem(at: fixture.reader.appending(path: "已删除目录"))
        try write("untouched", to: fixture.mac.appending(path: "已删除目录/额外文件.txt"))

        let quick = try await DirectorySync.compare(direction, local: root, remote: fixture.root, on: fixture.device,
                                                    baseline: baseline)
        let verified = try await DirectorySync.compare(direction, local: root, remote: fixture.root, on: fixture.device,
                                                       verifyContents: true, baseline: baseline)
        func changes(_ rows: [DirectorySync.Row]) -> [String: DirectorySync.Row.BaselineChange] {
            Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                row.baselineChange.map { (row.path, $0) }
            })
        }
        #expect(changes(quick) == ["Mac缺失.txt": .missingOnMac, "已删除目录": .missingOnDevice])
        #expect(verified.allSatisfy { $0.step == nil })
        #expect(changes(verified) == [
            "Mac.txt": .macModified, "Device.txt": .deviceModified, "Both.txt": .bothModified,
            "Mac缺失.txt": .missingOnMac, "已删除目录": .missingOnDevice,
        ])
        #expect(verified.contains { $0.path == "一致.txt" && $0.kind == .identical })
        let updated = try reopened.recordMatches(verified, previous: baseline, for: id)
        #expect(Set(updated.keys) == Set(baseline.keys))
        #expect(updated["Both.txt"] == baseline["Both.txt"])
        #expect(updated["一致.txt"] != baseline["一致.txt"])
        try write("Mac new", to: fixture.mac.appending(path: "新增/本地.txt"))
        try write("Device new", to: fixture.reader.appending(path: "新增/设备.txt"))
        let plan = try await DirectorySync.planBidirectional(local: root, remote: fixture.root,
                                                             on: fixture.device, baseline: baseline)
        let actions = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.path, $0.action) })
        #expect(actions == [
            "Mac.txt": .updateDevice, "Device.txt": .updateMac, "Both.txt": .review,
            "Mac缺失.txt": .review, "已删除目录": .review, "一致.txt": .identical,
            "新增/本地.txt": .addToDevice, "新增/设备.txt": .addToMac,
        ])
        #expect(plan.rows.first { $0.path == "Device.txt" }?.direction == .toMac)
        #expect(plan.rows.first { $0.path == "Mac.txt" }?.direction == .toDevice)
        #expect(!FileManager.default.fileExists(atPath: fixture.mac.appending(path: "新增/设备.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.reader.appending(path: "新增/本地.txt").path))
        try reopened.remove(for: id)
        #expect(try reopened.load(for: id).isEmpty)
    }

    @Test func bidirectionalPlanHandlesEmptyFoldersAndAmbiguousNames() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.mac.appending(path: "Mac-empty"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: fixture.reader.appending(path: "N10-empty"), withIntermediateDirectories: false)
        try write("mac", to: fixture.mac.appending(path: "NAME.txt"))
        try write("n10", to: fixture.reader.appending(path: "name.txt"))
        try write("regular", to: fixture.mac.appending(path: "类型"))
        try write("nested", to: fixture.reader.appending(path: "类型/设备.txt"))
        try write("hidden", to: fixture.reader.appending(path: ".hidden"))
        let plan = try await DirectorySync.planBidirectional(local: .init(fixture.mac), remote: fixture.root,
                                                             on: fixture.device, baseline: [:])
        #expect(plan.rows.filter { $0.action == .review }.map(\.path).sorted() == ["NAME.txt", "类型"].sorted())
        #expect(plan.rows.first { $0.path == "Mac-empty" }?.action == .addToDevice)
        #expect(plan.rows.first { $0.path == "N10-empty" }?.action == .addToMac)
        #expect(plan.rows.first { $0.path == ".hidden" }?.action == .ignored)
        #expect(!plan.rows.contains { $0.path.hasPrefix("类型/") })
        for row in plan.rows where row.action == .review {
            #expect(!row.canResolve)
            #expect(row.resolving(.toDevice).step == nil)
            #expect(row.resolving(.toMac).step == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.mac.appending(path: "N10-empty").path))
    }

    @Test(arguments: DirectorySync.Direction.allCases, [true, false])
    func manualConflictResolutionBacksUpChosenDestination(direction: DirectorySync.Direction,
                                                        hasBaseline: Bool) async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let path = "冲突/版本.txt"
        let mac = fixture.mac.appending(path: path)
        let reader = fixture.reader.appending(path: path)
        try write("baseline", to: mac)
        let baseline = try DirectorySync.fingerprint(of: mac)
        try write("Mac revision", to: mac)
        try write("N10 revision with different length", to: reader)
        let plan = try await DirectorySync.planBidirectional(local: .init(fixture.mac), remote: fixture.root,
                                                             on: fixture.device,
                                                             baseline: hasBaseline ? [path: baseline] : [:])
        let original = try #require(plan.rows.first { $0.path == path })
        #expect(original.action == .review)
        #expect(original.canResolve)
        #expect(original.step == nil)
        #expect(original.resolving(nil).step == nil)
        let resolved = original.resolving(direction)
        #expect(resolved.id == original.id)
        #expect(resolved.direction == direction)
        let step = try #require(resolved.step)
        let persisted = try JSONDecoder().decode(TransferStep.self, from: JSONEncoder().encode(step))
        let chosen = direction == .toDevice ? "Mac revision" : "N10 revision with different length"
        let previous = direction == .toDevice ? "N10 revision with different length" : "Mac revision"
        let store = SyncBackupStore(directory: fixture.directory.appending(path: "backups"))
        try await updateExecutor(in: fixture, backups: store).execute(persisted, progress: nil)
        #expect(try String(contentsOf: mac, encoding: .utf8) == chosen)
        #expect(try String(contentsOf: reader, encoding: .utf8) == chosen)
        #expect(try await store.record(step.id)?.completed == true)
        let files = try await store.files(step.id)
        #expect(try String(contentsOf: files.previous, encoding: .utf8) == previous)
        #expect(try String(contentsOf: files.source, encoding: .utf8) == chosen)
    }

    @Test(arguments: DirectorySync.Direction.allCases, [true, false])
    func manualConflictRejectsChangesAfterChoice(direction: DirectorySync.Direction, changeSource: Bool) async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mac = fixture.mac.appending(path: "冲突.txt")
        let reader = fixture.reader.appending(path: "冲突.txt")
        try write("Mac initial", to: mac)
        try write("N10 initial", to: reader)
        let plan = try await DirectorySync.planBidirectional(local: .init(fixture.mac), remote: fixture.root,
                                                             on: fixture.device, baseline: [:])
        let row = try #require(plan.rows.first)
        let step = try #require(row.resolving(direction).step)
        let changed = (direction == .toDevice) == changeSource ? mac : reader
        try write("external edit after choice", to: changed)
        let beforeMac = try Data(contentsOf: mac)
        let beforeReader = try Data(contentsOf: reader)
        let store = SyncBackupStore(directory: fixture.directory.appending(path: "backups"))
        let executor = try updateExecutor(in: fixture, backups: store)
        await #expect(throws: ToolboxError.self) { try await executor.execute(step, progress: nil) }
        #expect(try Data(contentsOf: mac) == beforeMac)
        #expect(try Data(contentsOf: reader) == beforeReader)
        #expect(try await store.load().isEmpty)
    }

    @Test func bulkPlanSelectionRespectsFiltersAndLeavesStructuralConflictsUnchanged() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        try write("local new", to: fixture.mac.appending(path: "Mac新增.txt"))
        try write("reader new", to: fixture.reader.appending(path: "设备新增.txt"))
        for path in ["冲突A.txt", "冲突B.txt"] {
            try write("mac", to: fixture.mac.appending(path: path))
            try write("reader", to: fixture.reader.appending(path: path))
        }
        try write("regular", to: fixture.mac.appending(path: "类型冲突"))
        try write("nested", to: fixture.reader.appending(path: "类型冲突/子项.txt"))
        try write("same", to: fixture.mac.appending(path: "一致.txt"))
        try write("same", to: fixture.reader.appending(path: "一致.txt"))
        let rows = try await DirectorySync.planBidirectional(local: .init(fixture.mac), remote: fixture.root,
                                                             on: fixture.device, baseline: [:]).rows
        var selection = SyncPlanSelection(selected: Set(rows.filter { $0.step != nil }.map(\.id)))
        selection.selectVisible(rows, filter: .review, included: true)
        #expect(selection.selectedRows(rows).count == 2)
        selection.resolveVisible(rows, filter: .changes, using: .toMac)
        #expect(selection.resolutions.isEmpty)
        selection.resolveVisible(rows, filter: .review, using: .toDevice)
        #expect(selection.resolutions.count == 2)
        #expect(selection.selectedRows(rows).count { $0.direction == .toDevice } == 3)
        #expect(selection.selectedRows(rows).count { $0.direction == .toMac } == 1)
        let structural = try #require(rows.first { $0.path == "类型冲突" })
        #expect(selection.resolutions[structural.id] == nil)
        #expect(!selection.selected.contains(structural.id))
        let visibleIDs = Set(selection.visibleRows(rows, filter: .review).map(\.id))
        #expect(selection.selected.subtracting(visibleIDs).count == 2)

        selection.selectVisible(rows, filter: .review, included: false)
        #expect(Set(selection.selectedRows(rows).map(\.path)) == ["Mac新增.txt", "设备新增.txt"])
        selection.resolveVisible(rows, filter: .review, using: .toMac)
        #expect(selection.selectedRows(rows).count { $0.direction == .toMac } == 3)
        let originalChoices = selection.resolutions
        selection.resolveVisible(rows, filter: .identical, using: .toDevice)
        selection.selectVisible(rows, filter: .identical, included: true)
        #expect(selection.resolutions == originalChoices)
        #expect(selection.selectedRows(rows).count == 4)
        selection.resolveVisible(rows, filter: .changes, using: nil)
        #expect(selection.resolutions.isEmpty)
        #expect(selection.selectedRows(rows).count == 2)
        #expect(rows.filter { $0.canResolve }.allSatisfy { $0.step == nil })
    }

    @Test func bulkChosenStepsOnlyExecuteSelectedItemsAndKeepOldVersions() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        try write("new", to: fixture.mac.appending(path: "保持未选.txt"))
        for path in ["A.txt", "B.txt"] {
            try write("Mac content", to: fixture.mac.appending(path: path))
            try write("Device content", to: fixture.reader.appending(path: path))
        }
        let rows = try await DirectorySync.planBidirectional(local: .init(fixture.mac), remote: fixture.root,
                                                             on: fixture.device, baseline: [:]).rows
        var selection = SyncPlanSelection()
        selection.resolveVisible(rows, filter: .review, using: .toDevice)
        selection.selectVisible(rows, filter: .review, included: false)
        #expect(selection.selectedRows(rows).isEmpty)
        selection.selectVisible(rows, filter: .changes, included: true)
        // Leave the newly added file unchecked while executing the two resolved conflicts.
        selection.selected.remove(try #require(rows.first { $0.path == "保持未选.txt" }).id)
        let store = SyncBackupStore(directory: fixture.directory.appending(path: "backups"))
        let executor = try updateExecutor(in: fixture, backups: store)
        let steps = selection.selectedRows(rows).compactMap(\.step)
        #expect(steps.count == 2)
        for step in steps { try await executor.execute(step, progress: nil) }
        #expect(!FileManager.default.fileExists(atPath: fixture.reader.appending(path: "保持未选.txt").path))
        for path in ["A.txt", "B.txt"] {
            #expect(try String(contentsOf: fixture.reader.appending(path: path), encoding: .utf8) == "Mac content")
        }
        let records = try await store.load()
        #expect(records.count == 2)
        for record in records {
            let files = try await store.files(record.id)
            #expect(record.completed)
            #expect(try String(contentsOf: files.previous, encoding: .utf8) == "Device content")
        }
    }

    @Test(arguments: DirectorySync.Direction.allCases)
    func updatesAndRestoresWithPersistentBackups(direction: DirectorySync.Direction) async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let step = try await makeUpdateStep(in: fixture, direction: direction)
        let backups = SyncBackupStore(directory: fixture.directory.appending(path: "backups"))
        let executor = try updateExecutor(in: fixture, backups: backups)
        let destination = direction == .toMac ? fixture.mac : fixture.reader
        let file = destination.appending(path: "Version.txt")
        try await executor.execute(step, progress: nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new version")
        let backup = try #require(try await backups.record(step.id))
        #expect(backup.completed)
        let files = try await backups.files(step.id)
        #expect(try String(contentsOf: files.previous, encoding: .utf8) == "old")
        #expect(try String(contentsOf: files.source, encoding: .utf8) == "new version")

        let reopened = SyncBackupStore(directory: fixture.directory.appending(path: "backups"))
        let retryExecutor = try updateExecutor(in: fixture, backups: reopened)
        let restoredStep = try JSONDecoder().decode(TransferStep.self, from: JSONEncoder().encode(step))
        try await retryExecutor.execute(restoredStep, progress: nil)
        #expect(try await reopened.load().count == 1)

        let restore = SyncUpdate(path: backup.update.path, direction: direction,
                                 source: backup.update.destination,
                                 destination: try DirectorySync.fingerprint(of: file), restoringBackup: backup.id)
        let restoring = TransferStep(name: "Version.txt", action: .syncUpdate(restore))
        try await retryExecutor.execute(restoring, progress: nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        let savedCurrent = try await reopened.files(restoring.id)
        #expect(try String(contentsOf: savedCurrent.previous, encoding: .utf8) == "new version")
        #expect(try await reopened.load().count == 2)
    }

    @Test(arguments: DirectorySync.Direction.allCases)
    func refusesToOverwriteDestinationChangedAfterPreview(direction: DirectorySync.Direction) async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let step = try await makeUpdateStep(in: fixture, direction: direction)
        let destination = direction == .toMac ? fixture.mac : fixture.reader
        let file = destination.appending(path: "Version.txt")
        try write("external edit", to: file)
        let backups = SyncBackupStore(directory: fixture.directory.appending(path: "backups"))
        let executor = try updateExecutor(in: fixture, backups: backups)
        await #expect(throws: ToolboxError.self) { try await executor.execute(step, progress: nil) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "external edit")
        #expect(try await backups.load().isEmpty)
    }

    @Test(arguments: [true, false])
    func retriesAfterInterruptedPublishAndLostSuccessResponse(beforePublish: Bool) async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let step = try await makeUpdateStep(in: fixture, direction: .toDevice)
        let fault = SyncPublishFault(beforePublish: beforePublish)
        let device = SyncTestDevice(directory: fixture.reader,
                                    beforeRename: { from, to in try await fault.beforeRename(from, to: to) },
                                    afterRename: { from, to in try await fault.afterRename(from, to: to) })
        let directory = fixture.directory.appending(path: "backups")
        let store = SyncBackupStore(directory: directory)
        let executor = try updateExecutor(in: fixture, device: device, backups: store)
        let results = SyncUpdateResults()
        let error = await TransferBatch.run([step], executor: executor, progress: nil) { _, result in
            await results.record(result)
        }
        #expect(error != nil)
        #expect(await results.last?.canRetry == true)
        let interrupted = try #require(try await store.record(step.id))
        #expect(!interrupted.completed)
        let files = try await store.files(step.id)
        #expect(try String(contentsOf: files.previous, encoding: .utf8) == "old")
        let target = fixture.reader.appending(path: "Version.txt")
        if beforePublish {
            #expect(!FileManager.default.fileExists(atPath: target.path))
        } else {
            #expect(try String(contentsOf: target, encoding: .utf8) == "new version")
        }

        await fault.recover()
        // Retry keeps the exact new version prepared before interruption.
        try write("later source edit", to: fixture.mac.appending(path: "Version.txt"))
        let reopened = SyncBackupStore(directory: directory)
        let retried = try updateExecutor(in: fixture, device: device, backups: reopened)
        let persisted = try JSONDecoder().decode(TransferStep.self, from: JSONEncoder().encode(step))
        try await retried.execute(persisted, progress: nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "new version")
        #expect(try await reopened.load().count == 1)
        #expect(try await reopened.record(step.id)?.completed == true)
    }

    @Test func deviceTrashRestoresAsCopyAndKeepsOtherScopeProtected() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        try write("original", to: fixture.reader.appending(path: "书库/文件.txt"))
        let scope = Data("reader-one".utf8)
        let storeURL = fixture.directory.appending(path: "trash-records")
        let store = DeviceTrashStore(directory: storeURL)
        let parent = DeviceFolder.companion(path: "书库")
        let item = try #require(try await fixture.device.list(parent).first)
        try await store.put(item, parents: ["书库"], scope: scope, on: fixture.device, root: fixture.root)
        #expect(!FileManager.default.fileExists(atPath: fixture.reader.appending(path: "书库/文件.txt").path))
        let reopened = DeviceTrashStore(directory: storeURL)
        let record = try #require(try await reopened.load(scope: scope).first)
        await #expect(throws: ToolboxError.self) { _ = try await reopened.restore(record.id, scope: Data("other".utf8), on: fixture.device, root: fixture.root) }
        try write("new file", to: fixture.reader.appending(path: "书库/文件.txt"))
        let restored = try await reopened.restore(record.id, scope: scope, on: fixture.device, root: fixture.root)
        #expect(restored == "文件（恢复副本 1）.txt")
        #expect(try String(contentsOf: fixture.reader.appending(path: "书库/" + restored), encoding: .utf8) == "original")
        #expect(try String(contentsOf: fixture.reader.appending(path: "书库/文件.txt"), encoding: .utf8) == "new file")
        #expect(try await reopened.load().isEmpty)
    }

    @Test func deviceTrashPreservesMissingParentAndCanPurgeNestedFolder() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        try write("nested", to: fixture.reader.appending(path: "parent/folder/child.txt"))
        let store = DeviceTrashStore(directory: fixture.directory.appending(path: "trash-records"))
        let parent = DeviceFolder.companion(path: "parent")
        let item = try #require(try await fixture.device.list(parent).first)
        let scope = Data("reader".utf8)
        try await store.put(item, parents: ["parent"], scope: scope, on: fixture.device, root: fixture.root)
        try FileManager.default.removeItem(at: fixture.reader.appending(path: "parent"))
        let record = try #require(try await store.load().first)
        await #expect(throws: ToolboxError.self) { _ = try await store.restore(record.id, scope: scope, on: fixture.device, root: fixture.root) }
        #expect(try await store.load().count == 1)
        try await store.purge(record.id, scope: scope, on: fixture.device, root: fixture.root)
        #expect(try await store.load().isEmpty)
    }

    private func makeUpdateStep(in fixture: SyncFixture, direction: DirectorySync.Direction) async throws -> TransferStep {
        try write("old", to: fixture.mac.appending(path: "Version.txt"))
        try write("old", to: fixture.reader.appending(path: "Version.txt"))
        let first = try await DirectorySync.compare(direction, local: .init(fixture.mac), remote: fixture.root,
                                                     on: fixture.device, verifyContents: true)
        let fingerprint = try #require(first.first?.fingerprint)
        let source = direction == .toDevice ? fixture.mac : fixture.reader
        try write("new version", to: source.appending(path: "Version.txt"))
        let plan = try await DirectorySync.planBidirectional(local: .init(fixture.mac), remote: fixture.root,
                                                             on: fixture.device, baseline: ["Version.txt": fingerprint])
        return try #require(plan.rows.first?.step)
    }

    @Test func deviceCleanupPersistsAfterLocalRemovalAndDoesNotResurrectFromHistory() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let step = try await makeUpdateStep(in: fixture, direction: .toDevice)
        let store = SyncBackupStore(directory: fixture.directory.appending(path: "backups"))
        let executor = try updateExecutor(in: fixture, backups: store)
        try await executor.execute(step, progress: nil)
        let backup = try #require(try await store.record(step.id))
        let files = try await store.files(step.id)
        let moved = fixture.directory.appending(path: "moved-local-backup")
        try FileManager.default.moveItem(at: files.source.deletingLastPathComponent(), to: moved)
        #expect(try await store.deviceCopies().map(\.id) == [step.id])

        let device = SyncTestDevice(directory: fixture.reader, kind: .usb)
        let removed = try await store.cleanupDeviceCopy(step.id, scope: backup.scope, protectedIDs: [],
                                                       device: device, volumeRoot: fixture.root)
        #expect(removed)
        #expect(try String(contentsOf: fixture.reader.appending(path: "Version.txt"), encoding: .utf8) == "new version")
        #expect(try await store.deviceCopies(including: [backup]).isEmpty)
        try FileManager.default.moveItem(at: moved, to: files.source.deletingLastPathComponent())
        #expect(try await store.deviceCopies(including: [backup]).isEmpty)
        let request = try RecoveryCopyCleanup(backupID: step.id, originalName: "Version.txt",
                                              expected: backup.update.destination)
        #expect(try await device.cleanupRecoveryCopy(in: fixture.root, request: request) == false)
    }

    @Test(arguments: ["changed", "missingCurrent", "unfinishedStage", "protected", "wrongScope", "incomplete"])
    func deviceCleanupRejectsUnsafeState(scenario: String) async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let step = try await makeUpdateStep(in: fixture, direction: .toDevice)
        let store = SyncBackupStore(directory: fixture.directory.appending(path: "backups"))
        let executor = try updateExecutor(in: fixture, backups: store)
        try await executor.execute(step, progress: nil)
        var backup = try #require(try await store.record(step.id))
        let retained = fixture.reader.appending(path: ".HanvonToolbox-update-\(step.id.uuidString).old")
        switch scenario {
        case "changed": try write("bad", to: retained)
        case "missingCurrent": try FileManager.default.removeItem(at: fixture.reader.appending(path: "Version.txt"))
        case "unfinishedStage":
            try write("partial", to: fixture.reader.appending(path: ".HanvonToolbox-update-\(step.id.uuidString).new"))
        case "incomplete":
            backup.completed = false
            try await store.save(backup)
        default: break
        }
        let scope = scenario == "wrongScope"
            ? SyncBackupScope(device: Data("different".utf8), local: backup.scope.local, remotePath: [])
            : backup.scope
        let protected: Set<UUID> = scenario == "protected" ? [step.id] : []
        let device = SyncTestDevice(directory: fixture.reader, kind: .usb)
        await #expect(throws: ToolboxError.self) {
            try await store.cleanupDeviceCopy(step.id, scope: scope, protectedIDs: protected,
                                               device: device, volumeRoot: fixture.root)
        }
        #expect(FileManager.default.fileExists(atPath: retained.path))
        #expect(try await store.deviceCopies().map(\.id) == [step.id])
    }

    private func updateExecutor(in fixture: SyncFixture, device: (any DeviceConnection)? = nil,
                                backups: SyncBackupStore) throws -> TransferExecutor {
        let root = try DirectorySync.LocalRoot(fixture.mac)
        let scope = SyncBackupScope(device: Data("reader".utf8), local: root, remotePath: [])
        return TransferExecutor(device: device ?? fixture.device, volumeRoot: fixture.root, devicePath: [],
                                localRoot: fixture.mac, syncRoot: root, backupScope: scope, backups: backups)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}

private struct SyncFixture {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    var mac: URL { directory.appending(path: "Mac", directoryHint: .isDirectory) }
    var reader: URL { directory.appending(path: "Device", directoryHint: .isDirectory) }
    let root = DeviceFolder.companion(path: "")
    var device: SyncTestDevice { SyncTestDevice(directory: reader) }

    init() throws {
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reader, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func compare(_ direction: DirectorySync.Direction) async throws -> [DirectorySync.Row] {
        try await DirectorySync.compare(direction, local: .init(mac), remote: root, on: device)
    }

    func executor() throws -> TransferExecutor {
        try TransferExecutor(device: device, volumeRoot: root, devicePath: [], localRoot: mac, syncRoot: .init(mac))
    }
}

private actor SyncDownloadAudit {
    private(set) var copies: [String: URL] = [:]

    func record(_ name: String, at copy: URL) { copies[name] = copy }
}

private actor SyncUpdateResults {
    private(set) var last: TransferResult?
    func record(_ result: TransferResult) { last = result }
}

private actor SyncPublishFault {
    let beforePublish: Bool
    private var active = true

    init(beforePublish: Bool) { self.beforePublish = beforePublish }

    func beforeRename(_ from: String, to name: String) throws {
        if active, beforePublish, name == "Version.txt" { throw URLError(.networkConnectionLost) }
    }

    func afterRename(_ from: String, to name: String) throws {
        if active, !beforePublish, from.hasSuffix(".new"), name == "Version.txt" {
            active = false
            throw URLError(.networkConnectionLost)
        }
    }

    func recover() { active = false }
}

private struct SyncTestDevice: DeviceConnection {
    let directory: URL
    let kind: ConnectionKind
    let afterDownload: @Sendable (String, URL) async throws -> Void
    let beforeRename: @Sendable (String, String) async throws -> Void
    let afterRename: @Sendable (String, String) async throws -> Void

    init(directory: URL, kind: ConnectionKind = .companion,
         beforeRename: @escaping @Sendable (String, String) async throws -> Void = { _, _ in },
         afterRename: @escaping @Sendable (String, String) async throws -> Void = { _, _ in },
         afterDownload: @escaping @Sendable (String, URL) async throws -> Void = { _, _ in }) {
        self.directory = directory
        self.kind = kind
        self.afterDownload = afterDownload
        self.beforeRename = beforeRename
        self.afterRename = afterRename
    }

    func info() async throws -> DeviceInfo {
        .init(name: "Test reader", fields: [], volumes: [], supportsAPK: false, canManageFiles: true)
    }

    func list(_ folder: DeviceFolder) async throws -> [DeviceItem] {
        let path = try relativePath(folder)
        return try FileManager.default.contentsOfDirectory(at: url(path), includingPropertiesForKeys: nil).map {
            let relative = childPath($0.lastPathComponent, in: path)
            return try item(relative)
        }
    }

    func makeFolder(named name: String, in folder: DeviceFolder) async throws -> DeviceItem {
        let relative = childPath(name, in: try relativePath(folder))
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: false)
        return try item(relative)
    }

    func upload(_ file: URL, to folder: DeviceFolder, progress: ProgressUpdate?) async throws {
        let relative = childPath(file.lastPathComponent, in: try relativePath(folder))
        try FileManager.default.copyItem(at: file, to: url(relative))
    }

    func download(_ item: DeviceItem, to destination: URL, progress: ProgressUpdate?) async throws {
        guard case let .companion(path) = item.id else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.copyItem(at: url(path), to: destination)
        try await afterDownload(item.name, destination)
    }

    func close() async {}

    func delete(_ item: DeviceItem) async throws {
        guard case let .companion(path) = item.id else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.removeItem(at: url(path))
    }

    func relocate(_ item: DeviceItem, to folder: DeviceFolder, copying: Bool) async throws {
        guard case let .companion(path) = item.id else { throw CocoaError(.fileReadUnknown) }
        let destination = url(childPath(item.name, in: try relativePath(folder)))
        if copying { try FileManager.default.copyItem(at: url(path), to: destination) }
        else { try FileManager.default.moveItem(at: url(path), to: destination) }
    }

    func rename(_ item: DeviceItem, in folder: DeviceFolder, to name: String) async throws {
        guard case let .companion(path) = item.id else { throw CocoaError(.fileReadUnknown) }
        try await beforeRename(item.name, name)
        let parent = try relativePath(folder)
        try FileManager.default.moveItem(at: url(path), to: url(childPath(name, in: parent)))
        try await afterRename(item.name, name)
    }
    private func url(_ path: String) -> URL { path.isEmpty ? directory : directory.appending(path: path) }
    private func childPath(_ name: String, in path: String) -> String { path.isEmpty ? name : "\(path)/\(name)" }

    private func relativePath(_ folder: DeviceFolder) throws -> String {
        guard case let .companion(path) = folder else { throw CocoaError(.fileReadUnknown) }
        return path
    }

    private func item(_ path: String) throws -> DeviceItem {
        let file = url(path)
        let values = try file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let folder: DeviceFolder? = values.isDirectory == true ? .companion(path: path) : nil
        return DeviceItem(id: .companion(path: path), name: file.lastPathComponent, folder: folder,
                          size: values.fileSize.flatMap { UInt64(exactly: $0) })
    }
}
