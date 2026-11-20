import SwiftUI

struct BrowserControls: View {
    let model: ToolboxModel
    let pane: BrowserPane
    @State private var jumping = false
    @State private var path = ""
    private var canBack: Bool { pane == .mac ? !model.localNavigation.past.isEmpty : !model.remoteNavigation.past.isEmpty }
    private var canForward: Bool { pane == .mac ? !model.localNavigation.future.isEmpty : !model.remoteNavigation.future.isEmpty }
    var body: some View {
        HStack(spacing: 12) {
            Button { model.browseHistory(pane, forward: false) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("\(pane.title)后退").help("后退").disabled(!canBack || model.isBusy)
            Button { model.browseHistory(pane, forward: true) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("\(pane.title)前进").help("前进").disabled(!canForward || model.isBusy)
            Menu {
                Button("收藏当前目录") { model.addBookmark(pane) }
                ForEach(model.bookmarks(for: pane)) { item in
                    Button(item.title) { model.openBookmark(item) }.help(item.local?.path ?? item.names.joined(separator: "/"))
                }
                if !model.bookmarks(for: pane).isEmpty {
                    Divider()
                    Menu("移除收藏") {
                        ForEach(model.bookmarks(for: pane)) { item in Button(item.title) { model.removeBookmark(item.id) } }
                    }
                }
            } label: { Label("常用目录", systemImage: "star") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy || (pane == .device && !model.isConnected))
            Spacer()
            Button {
                path = pane == .mac ? model.localFolder.path : model.remotePath.dropFirst().map(\.name).joined(separator: "/")
                jumping = true
            } label: { Image(systemName: "arrow.turn.down.right") }
                .accessibilityLabel("跳转\(pane.title)目录").help("输入路径跳转")
                .disabled(model.isBusy || (pane == .device && !model.isConnected))
            Button {
                model.beginSearch(pane)
            } label: { Image(systemName: "folder.badge.magnifyingglass") }
                .accessibilityLabel("搜索\(pane.title)子目录").help("包含子目录的文件名搜索")
                .disabled(model.isBusy || (pane == .device && !model.isConnected))
        }
        .buttonStyle(.borderless)
        .font(.callout).padding(.horizontal, 14).frame(height: 30)
        .alert("跳转\(pane.title)目录", isPresented: $jumping) {
            TextField(pane == .mac ? "绝对路径或 ~/目录" : "相对设备存储根目录的路径", text: $path)
            Button("取消", role: .cancel) {}
            Button("前往") { model.jumpDirectory(path, pane: pane) }
        }
    }
}

struct BrowserSearchView: View {
    @Bindable var model: ToolboxModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(model.searchOnDevice ? "搜索电纸书子目录" : "搜索 Mac 子目录").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.disabled(model.isBusy)
            }
            TextField("输入文件名关键词", text: $model.searchQuery).textFieldStyle(.roundedBorder)
                .onSubmit { model.searchFiles() }.disabled(model.isBusy)
            HStack {
                Text("从当前目录递归搜索；跳过隐藏项目、符号链接和 Mac 文件包")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small); Button("取消") { model.cancel() } }
                else { Button("开始搜索") { model.searchFiles() }.disabled(model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            List(model.searchHits) { hit in
                HStack {
                    VStack(alignment: .leading) {
                        Text(hit.name)
                        Text(hit.path.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("定位") { model.revealSearchHit(hit) }.disabled(model.isBusy)
                }
            }
            Text("\(model.searchHits.count) 项结果 · \(model.status)").font(.caption).foregroundStyle(.secondary)
        }.padding().frame(width: 740, height: 500).interactiveDismissDisabled(model.isBusy)
    }
}
