import Foundation
import Testing
import ToolboxCore
@testable import HanvonToolbox

struct TransferHistoryStoreTests {
    @Test func reopeningPreservesActionsAndMakesOnlyUnfinishedRowsRetryable() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferHistoryStore(directory: directory)
        let empty = store.load()
        #expect(empty.records.isEmpty)
        #expect(empty.warning == nil)

        let source = directory.appending(path: "电子书.epub")
        let target = TransferDestination(connection: .companion, identity: "device", root: .companion(path: ""),
                                         volumeName: "共享目录", volumeIdentity: "directory", launchID: nil)
        var record = TransferRecord(title: "上传", target: target, remotePath: ["书库"], localFolder: directory, rows: [
            .init(step: .init(name: "完成", action: .makeDeviceFolders(["书库"])), result: .succeeded),
            .init(step: .init(name: "跳过", action: .download(path: ["已有.epub"], expectedSize: 12)),
                  result: .skipped("已有文件")),
            .init(step: .init(name: source.lastPathComponent, action: .upload(source, directories: ["分类"]))),
            .init(step: .init(name: "等待", action: .apk(directory.appending(path: "example.apk")))),
        ])
        try await store.save(record)
        record.rows[2].result = .running
        try await store.save(record)

        let reopened = TransferHistoryStore(directory: directory).load()
        let restored = try #require(reopened.records.first)
        #expect(reopened.records.count == 1)
        #expect(reopened.warning == nil)
        #expect(restored.id == record.id)
        #expect(restored.target == target)
        #expect(restored.remotePath == ["书库"])
        #expect(restored.localFolder == directory)
        #expect(restored.rows.map(\.id) == record.rows.map(\.id))
        #expect(restored.rows[0].result == .succeeded)
        #expect(restored.rows[1].result == .skipped("已有文件"))
        guard case .interrupted = restored.rows[2].result,
              case let .upload(restoredSource, directories) = restored.rows[2].step.action else {
            Issue.record("Missing interrupted upload")
            return
        }
        #expect(restoredSource == source)
        #expect(directories == ["分类"])
        #expect(restored.retryable.map(\.id) == record.rows.suffix(2).map(\.id))
    }

    @Test func unreadableBatchDoesNotHideOtherRecords() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferHistoryStore(directory: directory)
        let target = TransferDestination(connection: .usb, identity: "serial", root: .usb(storage: 1, parent: .max),
                                         volumeName: "USB", volumeIdentity: nil, launchID: nil)
        let record = TransferRecord(title: "下载", target: target, remotePath: [], localFolder: directory, rows: [
            .init(step: .init(name: "子目录", action: .makeLocalFolders(["子目录"])), result: .failed("目录不可用")),
        ])
        try await store.save(record)
        let damaged = directory.appending(path: "\(UUID().uuidString).json")
        try Data("incomplete".utf8).write(to: damaged)

        let loaded = store.load()
        #expect(loaded.records.map(\.id) == [record.id])
        #expect(loaded.records.first?.rows.first?.result == .failed("目录不可用"))
        #expect(loaded.warning != nil)
        #expect(FileManager.default.fileExists(atPath: damaged.path))
    }
}
