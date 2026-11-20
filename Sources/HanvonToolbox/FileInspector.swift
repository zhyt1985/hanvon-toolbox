import QuickLook
import SwiftUI
import ToolboxCore

struct FileInspector: View {
    let model: ToolboxModel
    let pane: BrowserPane
    @Binding var isPresented: Bool
    @State private var preview: URL?

    private var macPath: String { model.localFolder.path(percentEncoded: false) }
    private var devicePath: String { model.remotePath.map(\.name).joined(separator: " / ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("文件检查器", systemImage: "sidebar.right").font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭文件检查器")
            }
            .padding(.horizontal, 16)
            .frame(height: 57)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(pane.title).font(.callout).foregroundStyle(.secondary)
                    switch pane {
                    case .mac: macSelection
                    case .device: deviceSelection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .quickLookPreview($preview)
    }

    private var macSelection: some View {
        let items = model.selectedLocalItems
        return VStack(alignment: .leading, spacing: 16) {
            if items.count == 1, let item = items.first {
                details(item, sizeLabel: item.byteCount.map(formatBytes))
                metadata("所在目录", macPath)
                if let modified = item.modified {
                    metadata("修改时间", modified.formatted(date: .abbreviated, time: .shortened))
                }
                Divider()
                if item.isFolder {
                    Button("打开文件夹", systemImage: "folder") { model.openLocalSelection([item.id]) }
                } else {
                    Button("快速查看", systemImage: "eye") { preview = item.url }
                }
                Button("重命名…", systemImage: "pencil") { model.requestLocalName(for: item) }
                    .disabled(model.changingLocalName)
            } else {
                selectionSummary(items.count, path: macPath)
                Button("新建文件夹…", systemImage: "folder.badge.plus") { model.requestLocalName() }
                    .disabled(model.changingLocalName)
            }
            if !items.isEmpty, model.isConnected {
                Button(model.activeKind == .wifi ? "Wi-Fi 发送" : "上传到电纸书", systemImage: "arrow.right") {
                    model.upload(items.map(\.url))
                }
                .disabled(model.isBusy)
                if model.activeKind != .wifi, !devicePath.isEmpty {
                    metadata("上传到", devicePath)
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private var deviceSelection: some View {
        let items = model.selectedRemoteItems
        return VStack(alignment: .leading, spacing: 16) {
            if !model.isConnected {
                Text("连接电纸书后可查看设备文件。").foregroundStyle(.secondary)
            } else if items.count == 1, let item = items.first {
                details(item, sizeLabel: item.size.map(formatBytes) ?? item.sizeLabel)
                metadata("所在目录", devicePath)
                if let modified = item.modified { metadata("修改时间", modified.formatted(date: .abbreviated, time: .shortened)) }
                Divider()
                if item.isFolder {
                    Button("打开文件夹", systemImage: "folder") { model.openRemoteSelection([item.id]) }
                        .disabled(model.isBusy)
                } else {
                    Button("快速查看", systemImage: "eye") { model.previewRemote(item) }.disabled(model.isBusy)
                }
                if model.deviceInfo?.canManageFiles == true {
                    Button("重命名…", systemImage: "pencil") { model.nameRequest = NameRequest(item: item) }
                        .disabled(!model.canManage)
                }
            } else {
                selectionSummary(items.count, path: devicePath)
                if model.deviceInfo?.canManageFiles == true {
                    Button("新建文件夹…", systemImage: "folder.badge.plus") {
                        model.nameRequest = NameRequest(item: nil)
                    }
                    .disabled(!model.canManage)
                }
            }
            if !items.isEmpty, model.isConnected {
                Button("下载到 Mac", systemImage: "arrow.left") { model.download(items) }
                    .disabled(model.isBusy)
                metadata("下载到", macPath)
            }
        }
        .buttonStyle(.bordered)
    }

    private func details<Item: BrowserItem>(_ item: Item, sizeLabel: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: item.isFolder ? "folder.fill" : "doc")
                .font(.largeTitle)
                .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            Text(item.name)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(item.isFolder ? "文件夹" : sizeLabel ?? "文件")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func selectionSummary(_ count: Int, path: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(count == 0 ? "选择文件或文件夹" : "已选中 \(count) 项")
                .font(.headline)
            if !path.isEmpty { metadata("当前目录", path) }
        }
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
