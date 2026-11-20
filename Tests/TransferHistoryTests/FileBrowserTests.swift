import Testing
import ToolboxCore
@testable import HanvonToolbox

struct FileBrowserTests {
    @Test func changingFilterDropsHiddenSelectionsFromBatchActions() {
        let first = DeviceItem(id: .wifi(path: "/first"), name: "CAFÉ 2.pdf", size: 200)
        let second = DeviceItem(id: .wifi(path: "/second"), name: "读书笔记.txt", size: 80)
        let items = [first, second]
        var browser = FileBrowser(query: "  cafe  ")

        let remaining = browser.retainedSelection([first.id, second.id], in: items)
        #expect(browser.visible(items).map(\.id) == [first.id])
        #expect(remaining == [first.id])

        browser.query = ""
        #expect(browser.retainedSelection(remaining, in: items) == [first.id])
    }

    @Test func foldersStayFirstAndUnknownSizesStayLast() {
        let folder = DeviceItem(id: .wifi(path: "/books"), name: "书籍", folder: .wifi(path: "/books"))
        let small = DeviceItem(id: .wifi(path: "/small"), name: "Book 2.epub", size: 20)
        let large = DeviceItem(id: .wifi(path: "/large"), name: "Book 10.epub", size: 100)
        let unknown = DeviceItem(id: .wifi(path: "/unknown"), name: "Book 9.epub")
        let items = [unknown, large, folder, small]
        var browser = FileBrowser()

        #expect(browser.visible(items) == [folder, small, unknown, large])
        browser.order = .reverseName
        #expect(browser.visible(items) == [folder, large, unknown, small])
        browser.order = .smallFirst
        #expect(browser.visible(items) == [folder, small, large, unknown])
        browser.order = .largeFirst
        #expect(browser.visible(items) == [folder, large, small, unknown])
    }
}
