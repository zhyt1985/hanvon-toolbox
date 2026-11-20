import Testing
import ToolboxCore
@testable import HanvonToolbox

struct CompanionBrowseLocationTests {
    private let root = DeviceVolume(name: "共享目录", root: .companion(path: ""), identity: "original-root")
    private let library = DeviceItem(id: .companion(path: "书库"), name: "书库", folder: .companion(path: "书库"))
    private let shelf = DeviceItem(id: .companion(path: "书库/子目录"), name: "子目录",
                                  folder: .companion(path: "书库/子目录"))
    private let book = DeviceItem(id: .companion(path: "书库/子目录/书.epub"), name: "书.epub")

    @Test func restoresLatestDirectoryAndItsContents() async throws {
        let saved = CompanionBrowseLocation(rootIdentity: "original-root", names: ["书库", "子目录"])
        let result = try await CompanionBrowseLocation.resolve(saved, in: root) { folder in
            switch folder {
            case root.root: [library]
            case library.folder: [shelf]
            case shelf.folder: [book]
            default: throw ToolboxError.remoteItemMissing
            }
        }
        #expect(result.path.map(\.name) == ["共享目录", "书库", "子目录"])
        #expect(result.items == [book])
    }

    @Test func fallsBackToDeepestExistingParentIfChildDisappeared() async throws {
        let saved = CompanionBrowseLocation(rootIdentity: "original-root", names: ["书库", "子目录"])
        let result = try await CompanionBrowseLocation.resolve(saved, in: root) { folder in
            switch folder {
            case root.root: [library]
            case library.folder: [shelf]
            default: throw ToolboxError.remoteItemMissing
            }
        }
        #expect(result.path.map(\.name) == ["共享目录", "书库"])
        #expect(result.items == [shelf])
    }

    @Test func doesNotReuseDirectoryNamesOnAnotherAuthorizedRoot() async throws {
        let saved = CompanionBrowseLocation(rootIdentity: "different-root", names: ["书库"])
        let result = try await CompanionBrowseLocation.resolve(saved, in: root) { folder in
            #expect(folder == root.root)
            return [library]
        }
        #expect(result.path.map(\.name) == ["共享目录"])
    }
}
