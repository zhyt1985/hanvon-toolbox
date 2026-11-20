import SwiftUI
import ToolboxCore

struct SyncBackupsView: View {
    let model: ToolboxModel
    @Environment(\.dismiss) private var dismiss
    @State private var restoring: SyncBackup?
    @State private var clearing: SyncBackup?
    @State private var cleaningDevice: SyncBackup?
    @State private var showingDeviceCopies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("旧版本").font(.title2.weight(.semibold))
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Picker("备份位置", selection: $showingDeviceCopies) {
                Text("Mac 旧版本").tag(false)
                Text("设备恢复副本").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            if !showingDeviceCopies, !model.syncBackups.isEmpty {
                Text("\(model.syncBackups.count) 份旧版本 · Mac 副本合计 \(formatBytes(model.syncBackupFileBytes.values.reduce(0, +)))")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            if let error = model.syncBackupError {
                Text(error).foregroundStyle(.orange).padding(.horizontal, 16)
            }
            if let error = model.errorText {
                Text(error).font(.callout).foregroundStyle(.orange).padding(.horizontal, 16)
            }
            if showingDeviceCopies {
                deviceCopies
            } else if model.syncBackups.isEmpty {
                ContentUnavailableView("暂无旧版本", systemImage: "clock.arrow.circlepath",
                                       description: Text("双向同步更新文件前，会在这台 Mac 保存旧版本。"))
            } else {
                List(model.syncBackups) { backup in
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(backup.update.path.last ?? "文件").font(.headline)
                            Text(backup.update.path.joined(separator: "/"))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(backup.update.direction == .toDevice ? "电纸书" : "Mac") · \(formatBytes(backup.update.destination.byteCount)) · \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let bytes = model.syncBackupFileBytes[backup.id] {
                                Text("Mac 副本 \(formatBytes(bytes))").font(.caption).foregroundStyle(.secondary)
                            }
                            if !model.isBusy, let reason = model.backupCleanupReason(backup) {
                                Text(reason).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("恢复此版本") { restoring = backup }
                            .disabled(!model.canRestoreBackup(backup))
                            .help("连接原设备和存储后可恢复")
                        Menu("更多") {
                            Button("导出旧版本…") { model.exportSyncBackup(backup) }
                                .disabled(model.isBusy)
                            Button("清理 Mac 副本…") { clearing = backup }
                                .disabled(model.backupCleanupReason(backup) != nil)
                            if let copy = model.deviceRecoveryCopies.first(where: { $0.id == backup.id }) {
                                Button("清理设备恢复副本…") { cleaningDevice = copy }
                                    .disabled(model.deviceCopyCleanupReason(copy) != nil)
                            }
                        }
                        .fixedSize()
                        .accessibilityLabel("\(backup.update.path.last ?? "文件")的旧版本操作")
                    }
                    .buttonStyle(.bordered)
                    .padding(.vertical, 5)
                }
            }
            Text(model.isBusy ? model.activity ?? "正在恢复…" : model.status)
                .font(.callout).foregroundStyle(.secondary)
                .padding(16)
        }
        .frame(width: 700, height: 500)
        .task { await model.reloadSyncBackups() }
        .confirmationDialog("恢复旧版本？",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            presenting: restoring) { backup in
            Button("恢复「\(backup.update.path.last ?? "文件")」") { model.restoreBackup(backup) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("当前版本会先备份，然后写回所选旧版本。")
        }
        .confirmationDialog("清理 Mac 备份？",
                            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
                            presenting: clearing) { backup in
            Button("移到废纸篓", role: .destructive) { model.trashSyncBackup(backup) }
            Button("取消", role: .cancel) {}
        } message: { backup in
            Text("将「\(backup.update.path.last ?? "文件")」的本机备份移到 Mac 废纸篓，可通过访达放回原处。对应的设备清理记录会继续保存在「设备恢复副本」中。")
        }
        .confirmationDialog("永久清理设备恢复副本？",
                            isPresented: Binding(get: { cleaningDevice != nil }, set: { if !$0 { cleaningDevice = nil } }),
                            presenting: cleaningDevice) { copy in
            Button("校验并永久清理", role: .destructive) { model.cleanupDeviceRecoveryCopy(copy) }
            Button("取消", role: .cancel) {}
        } message: { copy in
            Text("将校验并永久删除「\(copy.update.path.last ?? "文件")」对应的 \(formatBytes(copy.update.destination.byteCount)) 设备隐藏副本。\(model.syncBackups.contains(where: { $0.id == copy.id }) ? "Mac 旧版本可继续用于恢复。" : "本机备份已清理，请确认已导出需要保留的旧版本。")")
        }
    }

    @ViewBuilder
    private var deviceCopies: some View {
        if model.deviceRecoveryCopies.isEmpty {
            ContentUnavailableView("暂无待清理的设备副本", systemImage: "book.closed",
                                   description: Text("已完成设备更新的恢复副本会显示在这里。"))
        } else {
            Text("\(model.deviceRecoveryCopies.count) 份记录 · 记录大小合计 \(formatBytes(model.deviceRecoveryCopies.reduce(0) { $0 + $1.update.destination.byteCount }))")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            List(model.deviceRecoveryCopies) { copy in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(copy.update.path.last ?? "文件").font(.headline)
                        Text((copy.scope.remotePath + copy.update.path).joined(separator: " / "))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(formatBytes(copy.update.destination.byteCount)) · \(copy.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !model.syncBackups.contains(where: { $0.id == copy.id }) {
                            Text("Mac 本机备份已清理").font(.caption).foregroundStyle(.secondary)
                        }
                        if !model.isBusy, let reason = model.deviceCopyCleanupReason(copy) {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("清理设备副本…") { cleaningDevice = copy }
                        .disabled(model.deviceCopyCleanupReason(copy) != nil)
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 5)
            }
        }
    }
}
