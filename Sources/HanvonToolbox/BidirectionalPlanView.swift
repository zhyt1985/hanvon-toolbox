import SwiftUI
import ToolboxCore

struct BidirectionalPlanView: View {
    let rows: [DirectorySync.PlanRow]
    let scopeMatches: Bool
    @Binding var selection: SyncPlanSelection
    @State private var filter = SyncPlanSelection.Filter.all

    var body: some View {
        let visible = selection.visibleRows(rows, filter: filter)
        let executable = selection.executableRows(visible)
        let conflicts = visible.filter(\.canResolve)
        let chosen = selection.selectedRows(rows)
        let hiddenCount = chosen.count { chosen in !visible.contains { $0.id == chosen.id } }
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("双向同步计划").font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("显示", selection: $filter) {
                    ForEach(SyncPlanSelection.Filter.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
                }
                .fixedSize()
            }
            .padding(12)

            HStack(spacing: 10) {
                Button("选择当前筛选") { selection.selectVisible(rows, filter: filter, included: true) }
                    .disabled(!scopeMatches || executable.allSatisfy { selection.selected.contains($0.id) })
                Button("取消选择当前筛选") { selection.selectVisible(rows, filter: filter, included: false) }
                    .disabled(!scopeMatches || !executable.contains { selection.selected.contains($0.id) })
                Spacer()
                Menu("批量处理冲突") {
                    Button("使用 Mac 版本（\(conflicts.count) 项）") {
                        selection.resolveVisible(rows, filter: filter, using: .toDevice)
                    }
                    Button("使用电纸书版本（\(conflicts.count) 项）") {
                        selection.resolveVisible(rows, filter: filter, using: .toMac)
                    }
                    Divider()
                    Button("暂不处理（\(conflicts.count) 项）") {
                        selection.resolveVisible(rows, filter: filter, using: nil)
                    }
                }
                .fixedSize()
                .disabled(!scopeMatches || conflicts.isEmpty)
                .help("仅修改当前筛选中已核对内容的文件冲突；核对预览后再同步")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if visible.isEmpty {
                ContentUnavailableView("这一类没有项目", systemImage: "checkmark.circle")
            } else {
                List(visible) { original in
                    let row = original.resolving(selection.resolutions[original.id])
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        if row.step != nil {
                            Toggle("选择 \(row.path)", isOn: Binding(
                                get: { selection.selected.contains(row.id) },
                                set: { included in
                                    if included { selection.selected.insert(row.id) }
                                    else { selection.selected.remove(row.id) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(!scopeMatches)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.path).lineLimit(1).truncationMode(.middle).help(row.path)
                            if let detail = row.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                            if original.canResolve, let mac = original.macFingerprint,
                               let reader = original.deviceFingerprint {
                                Text("Mac \(formatBytes(mac.byteCount)) · 电纸书 \(formatBytes(reader.byteCount))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if original.canResolve {
                            Picker("冲突处理：\(row.path)", selection: Binding<DirectorySync.Direction?>(
                                get: { selection.resolutions[row.id] },
                                set: { choice in selection.resolve(original, using: choice) }
                            )) {
                                Text("暂不处理").tag(DirectorySync.Direction?.none)
                                Text("使用 Mac 版本").tag(DirectorySync.Direction?.some(.toDevice))
                                Text("使用电纸书版本").tag(DirectorySync.Direction?.some(.toMac))
                            }
                            .labelsHidden()
                            .frame(width: 165)
                            .disabled(!scopeMatches)
                            .help("选择要保留的版本，另一端内容会先备份再更新")
                        }
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(row.action.rawValue)
                                .foregroundStyle(row.action == .review ? Color.orange : .primary)
                            if let direction = row.direction {
                                Text(direction.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                    .padding(.vertical, 3)
                }
            }
            VStack(spacing: 4) {
                if scopeMatches {
                    Text("已选 \(chosen.count) 项 · Mac → 电纸书 \(chosen.count { $0.direction == .toDevice }) 项 · 电纸书 → Mac \(chosen.count { $0.direction == .toMac }) 项")
                    if hiddenCount > 0 {
                        Text("其中 \(hiddenCount) 项不在当前筛选内，同步时仍会执行。")
                            .foregroundStyle(.orange)
                    }
                    Text("批量操作仅影响当前筛选。更新前备份旧版本，可从传输记录恢复。")
                } else {
                    Text("连接或目录已改变，请重新打开同步预设。")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .frame(maxHeight: .infinity)
    }

    private var summary: String {
        let resolved = rows.map { $0.resolving(selection.resolutions[$0.id]) }
        let added = resolved.count { $0.action == .addToMac || $0.action == .addToDevice }
        let updated = resolved.count { $0.action == .updateMac || $0.action == .updateDevice }
        let review = resolved.count { $0.action == .review }
        return "新增 \(added) 项 · 更新 \(updated) 项 · 需处理 \(review) 项"
    }
}
