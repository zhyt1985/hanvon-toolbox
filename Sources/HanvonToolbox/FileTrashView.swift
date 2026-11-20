import SwiftUI
import ToolboxCore

struct FileTrashView: View {
    let model: ToolboxModel
    @Environment(\.dismiss) private var dismiss
    @State private var purging: PendingPurge?
    private struct PendingPurge: Identifiable {
        let id: UUID
        let name: String
        let local: Bool
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件回收站").font(.title2.bold())
                Spacer()
                Button("刷新") { Task { await model.reloadTrash() } }.disabled(model.isBusy)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            List {
                Section("Mac · 工具箱回收站") {
                    if model.localTrash.isEmpty { Text("暂无回收文件").foregroundStyle(.secondary) }
                    ForEach(model.localTrash) { item in
                        row(item.name, path: item.original.path, date: item.date, id: item.id, local: true)
                    }
                }
                Section("设备 · 当前设备与存储") {
                    if model.deviceTrash.isEmpty { Text("暂无回收记录").foregroundStyle(.secondary) }
                    ForEach(model.deviceTrash) { item in
                        row(item.name, path: (item.parents + [item.name]).joined(separator: " / "),
                            date: item.date, id: item.id, local: false)
                    }
                }
            }
            Text("恢复到原目录；遇到同名文件时恢复为副本。设备记录绑定原设备和连接方式。")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 740, height: 500)
        .task { await model.reloadTrash() }
        .confirmationDialog("永久删除回收副本？", isPresented: Binding(
            get: { purging != nil }, set: { if !$0 { purging = nil } }), presenting: purging
        ) { item in
            Button("永久删除「\(item.name)」", role: .destructive) {
                model.restoreTrash(item.id, local: item.local, purge: true); purging = nil
            }
            Button("取消", role: .cancel) { purging = nil }
        } message: { _ in Text("此操作无法从回收站恢复。") }
    }
    private func row(_ name: String, path: String, date: Date, id: UUID, local: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fontWeight(.medium)
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(date.formatted()).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("恢复") { model.restoreTrash(id, local: local) }
            Button("永久删除…", role: .destructive) { purging = .init(id: id, name: name, local: local) }
        }.disabled(model.isBusy || (!local && !model.canCopyAndDelete))
    }
}
