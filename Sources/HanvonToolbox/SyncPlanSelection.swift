import Foundation
import ToolboxCore

struct SyncPlanSelection {
    enum Filter: String, CaseIterable {
        case all = "全部"
        case changes = "新增与更新"
        case review = "冲突与需处理"
        case identical = "已一致"
    }

    var selected: Set<UUID> = []
    var resolutions: [UUID: DirectorySync.Direction] = [:]

    func visibleRows(_ rows: [DirectorySync.PlanRow], filter: Filter) -> [DirectorySync.PlanRow] {
        rows.filter { row in
            let effective = row.resolving(resolutions[row.id])
            switch filter {
            case .all: return true
            case .changes: return effective.direction != nil
            case .review: return row.action == .review
            case .identical: return effective.action == .identical
            }
        }
    }

    func executableRows(_ rows: [DirectorySync.PlanRow]) -> [DirectorySync.PlanRow] {
        rows.map { $0.resolving(resolutions[$0.id]) }.filter { $0.step != nil }
    }

    func selectedRows(_ rows: [DirectorySync.PlanRow]) -> [DirectorySync.PlanRow] {
        executableRows(rows).filter { selected.contains($0.id) }
    }

    mutating func selectVisible(_ rows: [DirectorySync.PlanRow], filter: Filter, included: Bool) {
        let ids = Set(executableRows(visibleRows(rows, filter: filter)).map(\.id))
        if included { selected.formUnion(ids) }
        else { selected.subtract(ids) }
    }

    mutating func resolve(_ row: DirectorySync.PlanRow, using direction: DirectorySync.Direction?) {
        guard row.canResolve else { return }
        resolutions[row.id] = direction
        if direction != nil { selected.insert(row.id) }
        else { selected.remove(row.id) }
    }

    mutating func resolveVisible(_ rows: [DirectorySync.PlanRow], filter: Filter,
                                 using direction: DirectorySync.Direction?) {
        // Capture the visible set before resolutions change membership in the changes filter.
        let candidates = visibleRows(rows, filter: filter).filter(\.canResolve)
        for row in candidates { resolve(row, using: direction) }
    }
}
