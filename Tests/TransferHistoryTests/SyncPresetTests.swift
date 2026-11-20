import Foundation
import Testing
import ToolboxCore
@testable import HanvonToolbox

struct SyncPresetTests {
    private let root = DeviceFolder.companion(path: "")
    private let shelf = DeviceFolder.companion(path: "书库")
    private let books = DeviceFolder.companion(path: "书库/待同步")

    @Test func restoredPresetRequiresOriginalDeviceAndStorage() throws {
        let suite = "HanvonToolbox.Test.SyncPresets.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = SyncPresetStore(defaults: defaults)
        let original = try makePreset()
        #expect(try writer.load().isEmpty)
        try writer.save([original])

        let reopened = SyncPresetStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let presets = try reopened.load()
        #expect(presets == [original])
        let preset = try #require(presets.first)
        #expect(preset.matches(preset.target))
        #expect(!preset.matches(destination(identity: "different")))
        #expect(!preset.matches(destination(volumeIdentity: "different")))
        #expect(!preset.matches(nil))
        let unstable = try makePreset(target: destination(launchID: UUID()))
        #expect(!unstable.matches(unstable.target))

        try reopened.save([])
        #expect(try writer.load().isEmpty)
    }

    @Test func restoresExactPathAndRejectsMissingOrAmbiguousFolders() async throws {
        let preset = try makePreset()
        let volume = DeviceVolume(name: "共享目录", root: root, identity: "authorization")
        let shelfItem = DeviceItem(id: .companion(path: "书库"), name: "书库", folder: shelf)
        let booksItem = DeviceItem(id: .companion(path: "书库/待同步"), name: "待同步", folder: books)
        let sample = DeviceItem(id: .companion(path: "书库/待同步/样例.txt"), name: "样例.txt")
        let resolved = try await preset.resolve(in: volume) { folder in
            switch folder {
            case root: [shelfItem]
            case shelf: [booksItem]
            default: [sample]
            }
        }
        #expect(resolved.path.map(\.name) == ["共享目录", "书库", "待同步"])
        #expect(resolved.items == [sample])

        await #expect(throws: ToolboxError.self) {
            _ = try await preset.resolve(in: volume) { $0 == root ? [shelfItem] : [] }
        }
        await #expect(throws: ToolboxError.self) {
            _ = try await preset.resolve(in: volume) { $0 == root ? [shelfItem, shelfItem] : [booksItem] }
        }
        await #expect(throws: ToolboxError.self) {
            let wrongVolume = DeviceVolume(name: "共享目录", root: root, identity: "different")
            _ = try await preset.resolve(in: wrongVolume) { _ in [shelfItem] }
        }
    }

    private func makePreset(target: TransferDestination? = nil) throws -> SyncPreset {
        SyncPreset(name: "书库", local: try .init(URL.temporaryDirectory), target: target ?? destination(),
                   remotePath: ["书库", "待同步"], direction: .toMac)
    }

    private func destination(
        identity: String = "reader", volumeIdentity: String = "authorization", launchID: UUID? = nil
    ) -> TransferDestination {
        TransferDestination(connection: .companion, identity: identity, root: root,
                            volumeName: "共享目录", volumeIdentity: volumeIdentity, launchID: launchID)
    }
}
