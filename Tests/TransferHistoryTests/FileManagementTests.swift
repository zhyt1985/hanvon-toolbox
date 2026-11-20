import Foundation
import Testing
import ToolboxCore
@testable import HanvonToolbox

struct FileManagementTests {
    @Test func restoredUnicodeNamesFitBothFileSystemsAndRemainUnique() throws {
        let original = String(repeating: "书", count: 80) + ".pdf"
        let first = availableRestoredName(original, occupied: [original])
        let second = availableRestoredName(original, occupied: [original, first])
        try validateFileName(first)
        try validateFileName(second)
        #expect(first.utf8.count <= 255)
        #expect(second.utf8.count <= 255)
        #expect(first.hasSuffix(".pdf"))
        #expect(first != second)
    }
    @Test func localTrashSurvivesReopenAndRestoresWithoutReplacingCurrentFile() async throws {
        let base = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appending(path: "book.txt")
        try Data("old".utf8).write(to: file)
        let directory = base.appending(path: "trash")
        try await LocalTrashStore(directory: directory).put(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try Data("current".utf8).write(to: file)
        let reopened = LocalTrashStore(directory: directory)
        let record = try #require(try await reopened.load().first)
        let restored = try await reopened.restore(record.id)
        #expect(restored.lastPathComponent == "book（恢复副本 1）.txt")
        #expect(try Data(contentsOf: restored) == Data("old".utf8))
        #expect(try Data(contentsOf: file) == Data("current".utf8))
        try await reopened.put(restored)
        let purge = try #require(try await reopened.load().first)
        try await reopened.purge(purge.id)
        #expect(try await reopened.load().isEmpty)
        #expect(try Data(contentsOf: file) == Data("current".utf8))
    }

    @Test func navigationPreservesForwardUntilNewDestinationAndIgnoresRefresh() {
        var history = BrowserNavigation<String>()
        history.visit("A"); history.visit("B"); history.visit("C")
        #expect(history.back() == "B")
        history.visit("B")
        #expect(history.forward() == "C")
        #expect(history.back() == "B")
        history.visit("D")
        #expect(history.forward() == nil)
        #expect(history.past == ["A", "B"])
    }

    @Test func recursiveSearchSkipsSymlinksHiddenFilesAndPackages() throws {
        let base = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        for path in ["visible/book.txt", ".hidden/book.txt", "Sample.app/book.txt"] {
            let file = base.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("sample".utf8).write(to: file)
        }
        try FileManager.default.createSymbolicLink(at: base.appending(path: "link"), withDestinationURL: base.appending(path: "visible"))
        let results = try ToolboxModel.searchLocalFiles(base, query: "book")
        #expect(results.map { $0.1.joined(separator: "/") } == ["visible/book.txt"])
    }

    @Test func timeSortKeepsUnknownDatesLast() {
        let a = DeviceItem(id: .wifi(path: "a"), name: "a", modified: Date(timeIntervalSince1970: 1))
        let b = DeviceItem(id: .wifi(path: "b"), name: "b", modified: Date(timeIntervalSince1970: 2))
        let unknown = DeviceItem(id: .wifi(path: "c"), name: "c")
        #expect(FileBrowser(order: .newest).visible([a, unknown, b]) == [b, a, unknown])
        #expect(FileBrowser(order: .oldest).visible([a, unknown, b]) == [a, b, unknown])
    }

    @Test func queueReorderProtectsActiveAndCompletedRowsAndPersistsPause() async throws {
        let base = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = TransferDestination(connection: .usb, identity: "serial", root: .usb(storage: 1, parent: .max), volumeName: "USB", volumeIdentity: nil, launchID: nil)
        func row(_ name: String, _ result: TransferResult) -> TransferRecord.Row {
            .init(step: .init(name: name, action: .makeDeviceFolders([name])), result: result)
        }
        var record = TransferRecord(title: "queue", target: target, remotePath: [], localFolder: nil,
                                     rows: [row("done", .succeeded), row("active", .running), row("B", .waiting), row("C", .waiting), row("cancelled", .cancelled)])
        record.movePending(record.rows[3].id, by: -1, active: record.rows[1].id)
        #expect(record.rows.map { $0.step.name } == ["done", "active", "C", "B", "cancelled"])
        record.paused = true; record.autoResume = true
        record.rows[1].resumedFrom = 1024
        try await TransferHistoryStore(directory: base).save(record)
        let restored = try #require(TransferHistoryStore(directory: base).load().records.first)
        #expect(restored.paused == true)
        #expect(restored.autoResume == true)
        #expect(restored.rows[1].resumedFrom == 1024)
        #expect(restored.retryable.map(\.name) == ["active", "C", "B"])
        #expect(restored.rows.last?.result == .cancelled)
    }
}
