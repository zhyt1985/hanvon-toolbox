import SwiftUI
import ToolboxCore

struct SyncPreview {
    let direction: DirectorySync.Direction
    let local: DirectorySync.LocalRoot
    let target: TransferDestination
    let path: [String]
    let folder: DeviceFolder
    let session: String
    let rows: [DirectorySync.Row]
    let presetID: UUID?
    let baselineCount: Int?
    let bidirectionalPlan: [DirectorySync.PlanRow]?
    var selectedPlanRows: Set<UUID>?
    var planResolutions: [UUID: DirectorySync.Direction] = [:]
}

extension DirectorySync.Direction {
    var title: String {
        switch self {
        case .toDevice: "Mac → 电纸书"
        case .toMac: "电纸书 → Mac"
        }
    }
}

struct SyncView: View {
    let model: ToolboxModel
    let confirm: (SyncPreview) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var direction = DirectorySync.Direction.toDevice
    @State private var filter = Filter.all
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var removingPreset: SyncPreset?
    @State private var presetMessage: String?
    @State private var planSelection = SyncPlanSelection()

    private enum Filter: String, CaseIterable {
        case all = "全部"
        case planned = "待复制"
        case conflicts = "冲突"
        case identical = "已一致"
        case changes = "基线变化"
        case ignored = "保留与忽略"

        func includes(_ row: DirectorySync.Row) -> Bool {
            switch self {
            case .all: true
            case .planned: row.step != nil
            case .conflicts: row.kind == .conflict
            case .identical: row.kind == .identical
            case .changes: row.baselineChange != nil
            case .ignored: row.kind == .keepDestination || row.kind == .excluded
            }
        }
    }

    var body: some View {
        let preview = model.syncPreview
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("目录比较与同步", systemImage: "arrow.left.arrow.right")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if preview?.bidirectionalPlan != nil {
                        Text("Mac ↔ 电纸书")
                            .font(.headline)
                            .frame(width: 258)
                    } else {
                        Picker("同步方向", selection: Binding(get: { direction }, set: { value in
                            guard direction != value else { return }
                            direction = value
                            filter = .all
                            if model.syncPreview?.presetID != nil {
                                model.compareDirectories(value)
                            } else {
                                model.clearSyncPreview()
                            }
                        })) {
                            ForEach(DirectorySync.Direction.allCases, id: \.self) { direction in
                                Text(direction.title).tag(direction)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("同步方向")
                        .frame(width: 258)
                        .disabled(model.comparingDirectories)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    presetMenu
                    if let message = presetMessage ?? model.syncPresetStorageError {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let count = preview?.baselineCount {
                        Text(count == 0 ? "尚未记录基线" : "已记录基线 \(count) 项")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    directory("Mac", preview?.bidirectionalPlan != nil ? "同步目录" : (direction == .toDevice ? "来源" : "目标"),
                              preview?.local.url.path ?? model.localFolder.path)
                    directory("电纸书", preview?.bidirectionalPlan != nil ? "同步目录" : (direction == .toDevice ? "目标" : "来源"),
                              (preview?.path ?? model.remotePath.map(\.name)).joined(separator: " / "))
                }
            }
            .padding(20)

            Divider()
            if model.comparingDirectories {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(model.verifyingSyncContents ? "正在核对同名文件内容…" : "正在比较目录和子文件夹…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let preview {
                if let plan = preview.bidirectionalPlan {
                    BidirectionalPlanView(rows: plan, scopeMatches: model.syncScopeMatches(preview),
                                          selection: $planSelection)
                } else {
                    results(preview)
                }
            } else if let error = model.syncError {
                ContentUnavailableView("目录比较未完成", systemImage: "exclamationmark.circle",
                                       description: Text(error))
            } else if !model.isConnected {
                ContentUnavailableView("连接电纸书后比较目录", systemImage: "book.closed",
                                       description: Text("连接前可以查看已保存的同步预设。"))
            } else {
                ContentUnavailableView("比较当前打开的两个目录", systemImage: "folder.badge.questionmark",
                                       description: Text("包含子文件夹。比较完成后可预览待复制的文件和同名冲突。"))
            }
            Divider()

            HStack {
                if model.comparingDirectories {
                    Button(model.verifyingSyncContents ? "取消核对" : "取消比较") { model.cancel() }
                } else {
                    Button("关闭", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(preview?.bidirectionalPlan != nil ? "返回单向预览" : (preview == nil ? "比较目录" : "重新比较")) {
                    filter = .all
                    model.compareDirectories(direction)
                }
                .disabled(!model.canCompareDirectories)

                if let preview {
                    if preview.bidirectionalPlan == nil, preview.rows.contains(where: \.canVerifyContent) {
                        Button(preview.presetID == nil ? "核对同名内容" : "核对内容与基线") {
                            filter = .all
                            model.compareDirectories(direction, verifyContents: true)
                        }
                        .help(preview.presetID == nil
                              ? "临时读取同名且大小相同的设备文件"
                              : "核对内容，并为此预设记录两端一致的文件")
                        .disabled(!model.canCompareDirectories || preview.direction != direction
                                  || !model.syncScopeMatches(preview))
                    }
                    if preview.presetID != nil, preview.bidirectionalPlan == nil {
                        Button("双向计划") {
                            model.compareDirectories(direction, verifyContents: true, bidirectional: true)
                        }
                        .disabled(!model.canCompareDirectories || !model.syncScopeMatches(preview))
                        .help("核对两端文件与基线，预览每个文件的建议方向")
                    }
                    if preview.bidirectionalPlan == nil {
                        Button("开始同步") { confirm(preview) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canCompareDirectories || preview.direction != direction
                                      || !model.syncScopeMatches(preview)
                                      || !preview.rows.contains { $0.step != nil })
                    } else if let plan = preview.bidirectionalPlan {
                        Button("备份并同步所选") {
                            var confirmed = preview
                            confirmed.selectedPlanRows = planSelection.selected
                            confirmed.planResolutions = planSelection.resolutions
                            confirm(confirmed)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canCompareDirectories || !model.syncScopeMatches(preview)
                                  || planSelection.selectedRows(plan).isEmpty)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 780, height: 540)
        .interactiveDismissDisabled(model.comparingDirectories)
        .onChange(of: preview?.direction) { _, newDirection in
            if let newDirection { direction = newDirection }
        }
        .onChange(of: preview?.bidirectionalPlan?.map(\.id)) { _, _ in
            planSelection = SyncPlanSelection(
                selected: Set(preview?.bidirectionalPlan?.filter { $0.step != nil }.map(\.id) ?? [])
            )
        }
        .onChange(of: model.comparingDirectories) { _, running in
            if !running, let current = model.syncPreview?.direction { direction = current }
        }
        .alert("保存同步预设", isPresented: $namingPreset) {
            TextField("预设名称", text: $presetName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                do {
                    try model.saveSyncPreset(named: presetName, direction: direction)
                    presetMessage = "已保存「\(presetName.trimmingCharacters(in: .whitespacesAndNewlines))」"
                } catch {
                    presetMessage = error.localizedDescription
                }
            }
        } message: {
            Text("保存当前两端目录和复制方向。")
        }
        .confirmationDialog(
            "删除同步预设？",
            isPresented: Binding(get: { removingPreset != nil }, set: { if !$0 { removingPreset = nil } }),
            presenting: removingPreset
        ) { preset in
            Button("删除「\(preset.name)」", role: .destructive) {
                do {
                    try model.removeSyncPreset(preset.id)
                    presetMessage = "已删除预设「\(preset.name)」"
                } catch {
                    presetMessage = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("仅删除保存在 Mac 上的预设。")
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(model.syncPresets) { preset in
                Button(preset.name) {
                    presetMessage = nil
                    filter = .all
                    model.openSyncPreset(preset)
                }
                .help(preset.direction.title + " · " + preset.target.connection.rawValue)
            }
            if !model.syncPresets.isEmpty { Divider() }
            Button("保存当前目录为预设…") {
                presetName = ""
                namingPreset = true
            }
            .disabled(!model.canSaveSyncPreset || model.syncPreview.map { !model.syncScopeMatches($0) } == true)

            if !model.syncPresets.isEmpty {
                Menu("删除预设") {
                    ForEach(model.syncPresets) { preset in
                        Button(preset.name) { removingPreset = preset }
                    }
                }
            }
        } label: {
            Label("同步预设", systemImage: "bookmark")
        }
        .fixedSize()
        .disabled(!model.canOpenSyncPreset)
    }

    private func directory(_ title: String, _ role: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title) · \(role)").font(.subheadline.weight(.medium))
            Text(path.isEmpty ? "目录不可用" : path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }

    private func results(_ preview: SyncPreview) -> some View {
        let rows = preview.rows
        let visible = rows.filter(filter.includes)
        return VStack(spacing: 0) {
            HStack {
                Text("待复制 \(rows.count(where: Filter.planned.includes)) 项 · 冲突 \(rows.count(where: Filter.conflicts.includes)) 项 · 已一致 \(rows.count(where: Filter.identical.includes)) 项")
                    .font(.headline)
                Spacer()
                Picker("显示", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
                }
                .fixedSize()
            }
            .padding(12)

            if visible.isEmpty {
                ContentUnavailableView(rows.isEmpty ? "没有待比较的文件" : "这一类没有项目",
                                       systemImage: "checkmark.circle")
            } else {
                List(visible) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(row.path)
                            if let detail = row.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(row.baselineChange?.rawValue ?? row.kind.rawValue)
                            .foregroundStyle(row.kind == .conflict ? Color.orange : .secondary)
                            .font(.callout)
                    }
                    .padding(.vertical, 3)
                }
            }
            Text(model.syncScopeMatches(preview)
                 ? model.syncError ?? footer(for: preview)
                 : "连接或目录已改变，请重新比较。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .frame(maxHeight: .infinity)
    }

    private func footer(for preview: SyncPreview) -> String {
        preview.presetID == nil
            ? "只复制目标缺少的项目。同名文件会跳过，目标已有项目会保留。"
            : "只复制目标缺少且没有基线记录的项目。基线变化保留两端现状。"
    }
}
