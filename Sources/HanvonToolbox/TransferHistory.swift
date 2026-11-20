import Foundation
import SwiftUI
import ToolboxCore

struct TransferDestination: Codable, Equatable, Sendable {
    let connection: ConnectionKind
    let identity: String
    let root: DeviceFolder
    let volumeName: String
    let volumeIdentity: String?
    let launchID: UUID?
}

struct TransferRecord: Identifiable, Codable, Sendable {
    struct Row: Identifiable, Codable, Sendable {
        var id: UUID { step.id }
        let step: TransferStep
        var result = TransferResult.waiting
        var resumedFrom: UInt64?

        init(step: TransferStep, result: TransferResult = .waiting) {
            self.step = step
            self.result = result
        }

        init?(syncConflict row: DirectorySync.Row) {
            guard row.kind == .conflict else { return nil }
            let reason = [row.baselineChange?.rawValue, row.detail].compactMap { $0 }.joined(separator: " · ")
            self.init(step: .init(name: row.path, action: .syncConflict),
                      result: .skipped(reason.isEmpty ? "目标已有同名项目。" : reason))
        }
    }

    let id: UUID
    let createdAt: Date
    let title: String
    let target: TransferDestination
    let remotePath: [String]
    let localFolder: URL?
    let syncRoot: DirectorySync.LocalRoot?
    let backupScope: SyncBackupScope?
    var rows: [Row]
    var paused: Bool?
    var autoResume: Bool?

    init(title: String, target: TransferDestination, remotePath: [String], localFolder: URL?,
         syncRoot: DirectorySync.LocalRoot? = nil, backupScope: SyncBackupScope? = nil, rows: [Row]) {
        id = UUID()
        createdAt = Date()
        self.title = title
        self.target = target
        self.remotePath = remotePath
        self.localFolder = localFolder
        self.syncRoot = syncRoot
        self.backupScope = backupScope
        self.rows = rows
    }

    var summary: String {
        let counts = rows.reduce(into: (done: 0, skipped: 0, remaining: 0)) { counts, row in
            switch row.result {
            case .succeeded: counts.done += 1
            case .skipped, .cancelled: counts.skipped += 1
            default: counts.remaining += 1
            }
        }
        return "完成 \(counts.done) · 跳过 \(counts.skipped) · 未完成 \(counts.remaining)"
    }

    var retryable: [TransferStep] {
        rows.filter { $0.result.canRetry }.map(\.step)
    }

    mutating func movePending(_ id: UUID, by offset: Int, active: UUID?) {
        let indices = rows.indices.filter { rows[$0].result.canRetry && rows[$0].id != active }
        guard let position = indices.firstIndex(where: { rows[$0].id == id }),
              indices.indices.contains(position + offset) else { return }
        rows.swapAt(indices[position], indices[position + offset])
    }

    var requiredBackupIDs: Set<UUID> {
        var ids = Set<UUID>()
        for row in rows where row.result.canRetry || row.result == .running {
            if case let .syncUpdate(update) = row.step.action {
                ids.insert(row.id)
                if let original = update.restoringBackup { ids.insert(original) }
            }
        }
        return ids
    }

    var deviceRecoveryCopies: [SyncBackup] {
        guard let backupScope else { return [] }
        return rows.compactMap { row in
            guard row.result == .succeeded, case let .syncUpdate(update) = row.step.action,
                  update.direction == .toDevice else { return nil }
            return SyncBackup(id: row.id, createdAt: createdAt, scope: backupScope, update: update, completed: true)
        }
    }
}

struct TransferHistoryView: View {
    let model: ToolboxModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingBackups = false
    @State private var selectedRow: UUID?

    private var selected: (TransferRecord, TransferRecord.Row)? {
        for batch in model.transferHistory {
            if let row = batch.rows.first(where: { $0.id == selectedRow }) { return (batch, row) }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("传输记录").font(.title2.weight(.semibold))
                Spacer()
                Button("内容导出") { model.openContentExport() }
                Button("旧版本") { showingBackups = true }
                if model.isBusy {
                    if let id = model.activeBatchID,
                       let batch = model.transferHistory.first(where: { $0.id == id }) {
                        Button(batch.paused == true ? "继续队列" : "暂停队列") {
                            model.pauseQueue(id, paused: batch.paused != true)
                        }
                    }
                    if let progress = model.progress, let total = progress.total, total > 0 {
                        ProgressView(value: min(1, Double(progress.completed) / Double(total)))
                            .frame(width: 100)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("取消当前操作") { model.cancel() }
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            if let warning = model.transferHistoryWarning {
                Text(warning).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if model.transferHistory.isEmpty {
                ContentUnavailableView("暂无记录", systemImage: "arrow.left.arrow.right",
                                       description: Text(model.isBusy ? "正在准备文件列表…" : "传输后会在这里显示每个文件的结果。"))
            } else {
                List(selection: $selectedRow) {
                    ForEach(model.transferHistory.reversed()) { batch in
                        Section {
                            ForEach(batch.rows) { row in
                                rowView(row, batch: batch).tag(row.id)
                            }
                        } header: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(batch.title)
                                        .font(.headline)
                                    Text("\(batch.target.connection.rawValue) · \(batch.summary)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if batch.paused == true { Text("已暂停").font(.caption).foregroundStyle(.orange) }
                                }
                                Spacer()
                                if model.activeBatchID == batch.id || batch.paused == true {
                                    Button(batch.paused == true ? "继续" : "暂停") {
                                        model.pauseQueue(batch.id, paused: batch.paused != true)
                                    }
                                    .disabled(model.activeBatchID != batch.id && !model.canRetry(batch))
                                }
                                if !batch.retryable.isEmpty {
                                    Button("重试未完成") { model.retry(batch.id) }
                                        .disabled(!model.canRetry(batch))
                                        .help(model.retryHelp(batch))
                                }
                            }
                        }
                    }
                }
            }
            if let (batch, row) = selected {
                HStack {
                    Button("重试选中项") { model.retry(batch.id, rowID: row.id) }
                        .disabled(!row.result.canRetry || !model.canRetry(batch))
                    Button("取消选中项") { model.cancelRow(batch.id, row.id) }
                        .disabled(!row.result.canRetry && row.result != .running)
                    Button("提前") { model.moveQueuedRow(batch.id, row.id, by: -1) }
                        .disabled(!row.result.canRetry || row.id == model.activeRowID)
                    Button("延后") { model.moveQueuedRow(batch.id, row.id, by: 1) }
                        .disabled(!row.result.canRetry || row.id == model.activeRowID)
                    Spacer()
                    if batch.paused == true {
                        Button("继续此批次") { model.pauseQueue(batch.id, paused: false) }
                            .disabled(model.activeBatchID != batch.id && !model.canRetry(batch))
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            if model.activeBatchID != nil {
                HStack {
                    if let speed = model.transferRate { Text("\(formatBytes(UInt64(max(0, speed))))/秒") }
                    if let remaining = model.transferRemaining { Text("当前文件约剩 \(Int(remaining.rounded(.up))) 秒") }
                    Spacer()
                    Text(model.supportsByteResume ? "无线普通文件支持断点续传；完成文件会跳过" : "当前连接继续时重试当前文件；完成文件会跳过")
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .frame(width: 780, height: 520)
        .sheet(isPresented: $showingBackups) { SyncBackupsView(model: model) }
    }

    private func rowView(_ row: TransferRecord.Row, batch: TransferRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(row.result))
                .foregroundStyle(color(row.result))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.step.name).lineLimit(1).truncationMode(.middle)
                    .help(row.step.name)
                if let offset = row.resumedFrom {
                    Text("本次从 \(formatBytes(offset)) 继续").font(.caption).foregroundStyle(.secondary)
                }
                switch row.result {
                case let .skipped(reason), let .failed(reason), let .interrupted(reason):
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                default:
                    EmptyView()
                }
            }
            Spacer()
            Text(label(row.result))
                .font(.caption)
                .foregroundStyle(color(row.result))
            if row.result.canRetry || row.result == .running {
                Menu {
                    Button("重试此项") { model.retry(batch.id, rowID: row.id) }.disabled(!model.canRetry(batch))
                    Button("取消此项", role: .destructive) { model.cancelRow(batch.id, row.id) }
                    if row.id != model.activeRowID {
                        Divider()
                        Button("提前传输") { model.moveQueuedRow(batch.id, row.id, by: -1) }
                        Button("延后传输") { model.moveQueuedRow(batch.id, row.id, by: 1) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("\(row.step.name)的队列操作")
            }
        }
        .padding(.vertical, 3)
    }

    private func label(_ result: TransferResult) -> String {
        switch result {
        case .waiting: "等待"
        case .running: "传输中"
        case .succeeded: "完成"
        case .skipped: "已跳过"
        case .failed: "失败"
        case .interrupted: "已中断"
        case .cancelled: "已取消"
        }
    }

    private func icon(_ result: TransferResult) -> String {
        switch result {
        case .waiting: "clock"
        case .running: "arrow.left.arrow.right"
        case .succeeded: "checkmark.circle"
        case .skipped: "forward.end"
        case .failed: "exclamationmark.circle"
        case .interrupted: "pause.circle"
        case .cancelled: "xmark.circle"
        }
    }

    private func color(_ result: TransferResult) -> Color {
        switch result {
        case .succeeded: .green
        case .failed, .interrupted: .orange
        case .running: .accentColor
        case .waiting, .skipped, .cancelled: .secondary
        }
    }
}
