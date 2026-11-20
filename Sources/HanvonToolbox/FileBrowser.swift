import Foundation
import ToolboxCore

enum BrowserPane: Hashable {
    case mac
    case device

    var title: String { self == .mac ? "Mac" : "电纸书" }
}

protocol BrowserItem: Identifiable {
    var name: String { get }
    var isFolder: Bool { get }
    var byteCount: UInt64? { get }
    var modified: Date? { get }
}

extension LocalItem: BrowserItem {
    var byteCount: UInt64? { size.flatMap { UInt64(exactly: $0) } }
}

extension DeviceItem: BrowserItem {
    var byteCount: UInt64? { size }
}

struct FileBrowser {
    enum Order: String, CaseIterable {
        case name = "名称升序"
        case reverseName = "名称降序"
        case smallFirst = "大小升序"
        case largeFirst = "大小降序"
        case newest = "修改时间从新到旧"
        case oldest = "修改时间从旧到新"
    }

    var query = ""
    var order: Order = .name

    func matching<Item: BrowserItem>(_ items: [Item]) -> [Item] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? items : items.filter { $0.name.localizedStandardContains(term) }
    }

    func visible<Item: BrowserItem>(_ items: [Item]) -> [Item] {
        matching(items).sorted { left, right in
            if left.isFolder != right.isFolder { return left.isFolder }
            if order == .newest || order == .oldest {
                switch (left.modified, right.modified) {
                case (let lhs?, let rhs?) where lhs != rhs: return order == .newest ? lhs > rhs : lhs < rhs
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            if !left.isFolder, order == .smallFirst || order == .largeFirst {
                switch (left.byteCount, right.byteCount) {
                case (let lhs?, let rhs?) where lhs != rhs:
                    return order == .smallFirst ? lhs < rhs : lhs > rhs
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            let comparison = left.name.localizedStandardCompare(right.name)
            return comparison == (order == .reverseName ? .orderedDescending : .orderedAscending)
        }
    }

    func retainedSelection<Item: BrowserItem>(_ selection: Set<Item.ID>, in items: [Item]) -> Set<Item.ID> {
        selection.intersection(matching(items).map(\.id))
    }
}
