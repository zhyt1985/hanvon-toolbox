import SwiftUI
import ToolboxCore

struct LocalPane: View {
    @Bindable var model: ToolboxModel
    @Binding var activePane: BrowserPane
    let filterFocus: FocusState<BrowserPane?>.Binding
    let tableFocus: FocusState<BrowserPane?>.Binding
    @State private var browser = FileBrowser()

    private var filter: Binding<String> {
        Binding(get: { browser.query }, set: { query in
            browser.query = query
            model.localSelection = browser.retainedSelection(model.localSelection, in: model.localItems)
        })
    }

    var body: some View {
        let items = browser.visible(model.localItems)
        VStack(spacing: 0) {
            PaneTitle(title: "Mac", icon: "laptopcomputer", detail: nil, isActive: activePane == .mac) {
                Button {
                    activePane = .mac
                    model.chooseLocalFolder()
                } label: {
                    Label("选择文件夹", systemImage: "folder")
                }
            }

            BrowserControls(model: model, pane: .mac)
            HStack(spacing: 8) {
                Button {
                    activePane = .mac
                    model.openLocal(model.localFolder.deletingLastPathComponent())
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("上一级文件夹")
                .disabled(model.localFolder.path == "/")
                Text(model.localFolder.path(percentEncoded: false))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.localFolder.path(percentEncoded: false))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 37)
            .background(.quaternary.opacity(0.55))

            PaneFilter(query: filter, order: $browser.order, pane: .mac, focus: filterFocus)

            Table(items, selection: Binding(get: { model.localSelection }, set: { ids in
                if !ids.isEmpty { activePane = .mac }
                model.localSelection = ids
            })) {
                TableColumn("名称") { item in
                    FileNameCell(name: item.name, isFolder: item.isFolder)
                        .draggable(item.url)
                }
                .width(min: 150, ideal: 205)
                TableColumn("大小") { item in
                    if !item.isFolder, let size = item.byteCount {
                        Text(formatBytes(size)).foregroundStyle(.secondary)
                    }
                }
                .width(min: 75, ideal: 95, max: 120)
                TableColumn("修改时间") { item in
                    Text(item.modified?.formatted(date: .numeric, time: .omitted) ?? "—").foregroundStyle(.secondary)
                }.width(min: 80, ideal: 95, max: 130)
            }
            .focused(tableFocus, equals: .mac)
            .contextMenu(forSelectionType: URL.self) { ids in
                if ids.count == 1, let item = items.first(where: { ids.contains($0.id) }) {
                    Button("打开") { model.openLocalSelection(ids) }
                    if !item.isFolder { Button("快速查看") { model.previewURL = item.url } }
                    Button("重命名…") { model.requestLocalName(for: item) }
                        .disabled(model.changingLocalName)
                }
                if !ids.isEmpty {
                    Button("移入回收站", role: .destructive) { model.trashLocal(items.filter { ids.contains($0.id) }) }
                        .disabled(model.isBusy)
                    Button("发送到设备") {
                        model.upload(items.filter { ids.contains($0.id) }.map(\.url))
                    }
                    .disabled(!model.isConnected || model.isBusy)
                    Button("加入传输队列（稍后开始）") {
                        model.upload(items.filter { ids.contains($0.id) }.map(\.url), startImmediately: false)
                    }.disabled(!model.isConnected)
                }
                Button("新建文件夹…") { model.requestLocalName() }
                    .disabled(model.changingLocalName)
            } primaryAction: { ids in
                activePane = .mac
                model.openLocalSelection(ids)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(model.localItems.isEmpty ? "此目录为空" : "没有匹配项",
                                           systemImage: model.localItems.isEmpty ? "folder" : "magnifyingglass")
                        .allowsHitTesting(false)
                }
            }

            Divider()
            HStack {
                Text(selectionStatus(total: model.localItems.count, visible: items.count,
                                     selected: model.localSelection.count))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.upload(model.selectedLocalItems.map(\.url))
                } label: {
                    Label(model.activeKind == .wifi ? "Wi-Fi 发送" : "上传到设备", systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!model.isConnected || model.isBusy || model.localSelection.isEmpty)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .frame(height: 42)
        }
        .onChange(of: model.localFolder) { browser.query = "" }
    }
}

struct DevicePane: View {
    @Bindable var model: ToolboxModel
    @Binding var activePane: BrowserPane
    let filterFocus: FocusState<BrowserPane?>.Binding
    let tableFocus: FocusState<BrowserPane?>.Binding
    @State private var receivingDrop = false
    @State private var browser = FileBrowser()

    private var filter: Binding<String> {
        Binding(get: { browser.query }, set: { query in
            browser.query = query
            model.remoteSelection = browser.retainedSelection(model.remoteSelection, in: model.browsableRemoteItems)
        })
    }

    var body: some View {
        let items = browser.visible(model.browsableRemoteItems)
        VStack(spacing: 0) {
            PaneTitle(title: "电纸书", icon: "book.closed", detail: model.deviceInfo?.name,
                      isActive: activePane == .device) {
                if model.activeKind == .usb || model.activeKind == .companion {
                    Button { model.chooseAPK() } label: {
                        Label(model.activeKind == .companion ? "发起 APK 安装" : "发送 APK", systemImage: "shippingbox")
                    }
                    .disabled(!model.canSendAPK)
                }
                Menu {
                    Button("选择文件发送…") { model.chooseUpload() }
                        .disabled(!model.isConnected || model.isBusy)
                    if model.activeKind == .usb || model.activeKind == .companion {
                        Divider()
                        Button("新建文件夹…") { model.nameRequest = NameRequest(item: nil) }
                            .disabled(!model.canManage)
                        Button("粘贴到此处") { model.paste() }
                            .disabled(!model.canPaste)
                        if !model.selectedRemoteItems.isEmpty {
                            Divider()
                            actions(for: model.selectedRemoteItems)
                        }
                    }
                } label: {
                    Label("设备操作", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("设备操作")
            }

            BrowserControls(model: model, pane: .device)
            remoteBreadcrumbs

            PaneFilter(query: filter, order: $browser.order, pane: .device, focus: filterFocus)
                .disabled(!model.isConnected)

            if model.isConnected {
                Table(items, selection: Binding(get: { model.remoteSelection }, set: { ids in
                    if !ids.isEmpty { activePane = .device }
                    model.remoteSelection = ids
                })) {
                    TableColumn("名称") { item in
                        FileNameCell(name: item.name, isFolder: item.isFolder)
                    }
                    .width(min: 155, ideal: 250)
                    TableColumn("大小") { item in
                        if !item.isFolder {
                            Text(item.size.map(formatBytes) ?? item.sizeLabel ?? "—")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 75, ideal: 95, max: 120)
                    TableColumn("修改时间") { item in
                        Text(item.modified?.formatted(date: .numeric, time: .omitted) ?? "—").foregroundStyle(.secondary)
                    }.width(min: 80, ideal: 95, max: 130)
                }
                .focused(tableFocus, equals: .device)
                .contextMenu(forSelectionType: DeviceItem.ID.self) { ids in
                    let selection = items.filter { ids.contains($0.id) }
                    if selection.count == 1, selection[0].isFolder {
                        Button("打开文件夹") { model.openRemoteSelection(ids) }
                            .disabled(model.isBusy)
                    }
                    if !selection.isEmpty {
                        if selection.count == 1, !selection[0].isFolder {
                            Button("快速查看") { model.previewRemote(selection[0]) }.disabled(model.isBusy)
                        }
                        Button("下载到 Mac") { model.download(selection) }
                            .disabled(model.isBusy)
                        Button("加入下载队列（稍后开始）") { model.download(selection, startImmediately: false) }
                            .disabled(!model.isConnected)
                    }
                    if model.activeKind == .usb || model.activeKind == .companion {
                        if !selection.isEmpty { Divider() }
                        actions(for: selection)
                        Button("新建文件夹…") { model.nameRequest = NameRequest(item: nil) }
                            .disabled(!model.canManage)
                        Button("粘贴到此处") { model.paste() }
                            .disabled(!model.canPaste)
                    }
                } primaryAction: { ids in
                    activePane = .device
                    model.openRemoteSelection(ids)
                }
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView(model.browsableRemoteItems.isEmpty ? "此目录为空" : "没有匹配项",
                                               systemImage: model.browsableRemoteItems.isEmpty ? "folder" : "magnifyingglass")
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if receivingDrop && !model.isBusy {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !model.isBusy, !files.isEmpty else { return false }
                    model.upload(files)
                    return true
                } isTargeted: { receivingDrop = $0 }
            } else {
                ContentUnavailableView(
                    "连接电纸书", systemImage: model.mode == .usb ? "cable.connector" : "wifi",
                    description: Text(connectionInstructions)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                if model.activeKind == .wifi {
                    Text("Wi-Fi 上传由原厂传书接收")
                        .foregroundStyle(.secondary)
                } else {
                    Text(selectionStatus(total: model.browsableRemoteItems.count, visible: items.count,
                                         selected: model.remoteSelection.count))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.download(model.selectedRemoteItems)
                } label: {
                    Label("下载到 Mac", systemImage: "arrow.left")
                }
                .disabled(model.remoteSelection.isEmpty || model.isBusy)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .frame(height: 42)
        }
        .onChange(of: model.currentRemoteFolder) { previous, current in
            if previous != nil, current != nil { browser.query = "" }
        }
        .onChange(of: model.mode) { browser.query = "" }
    }

    private var remoteBreadcrumbs: some View {
        HStack(spacing: 8) {
            Button {
                activePane = .device
                model.goUp()
            } label: { Image(systemName: "arrow.up") }
                .help("上一级设备目录")
                .disabled(model.remotePath.count < 2 || model.isBusy)

            if model.locations.count > 1 {
                Menu("存储") {
                    ForEach(model.locations) { volume in
                    Button(volume.name) {
                        activePane = .device
                        model.openVolume(volume)
                    }
                    }
                }
                .fixedSize()
                .disabled(model.isBusy)
            }

            if model.remotePath.isEmpty {
                Text("未连接").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(Array(model.remotePath.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if index == model.remotePath.count - 1 {
                                Text(node.name)
                            } else {
                                Button(node.name) {
                                    activePane = .device
                                    model.navigate(Array(model.remotePath.prefix(index + 1)))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(model.isBusy)
                            }
                        }
                    }
                    .lineLimit(1)
                }
                .scrollIndicators(.hidden)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 37)
        .background(.quaternary.opacity(0.55))
    }

    private var connectionInstructions: String {
        switch model.mode {
        case .usb: return "连接数据线，在电纸书上选择文件传输，然后点「连接」。"
        case .wifi: return "在电纸书上开启 Wi-Fi 传书，输入设备显示的地址。"
        case .companion: return "在电纸书上开启无线管理后，Mac 会自动查找它。首次配对需要屏幕上的指纹和配对码。"
        }
    }

    @ViewBuilder
    private func actions(for items: [DeviceItem]) -> some View {
        if items.count == 1, let item = items.first {
            Button("重命名…") { model.nameRequest = NameRequest(item: item) }
                .disabled(!model.canManage)
        }
        if !items.isEmpty {
            if model.activeKind == .usb || model.activeKind == .companion {
                Button("复制到其他设备目录") { model.prepareRelocation(items, copying: true) }
                    .disabled(!model.canCopyAndDelete)
            }
            Button("移动到其他设备目录") { model.prepareRelocation(items, copying: false) }
                .disabled(!model.canManage)
            if model.activeKind == .usb || model.activeKind == .companion {
                Button("移入回收站…", role: .destructive) { model.deletionRequest = DeletionRequest(items: items) }
                    .disabled(!model.canCopyAndDelete)
            }
        }
    }
}

private struct PaneFilter: View {
    @Binding var query: String
    @Binding var order: FileBrowser.Order
    let pane: BrowserPane
    let focus: FocusState<BrowserPane?>.Binding

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选当前目录", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("筛选\(pane.title)当前目录")
                    .focused(focus, equals: pane)
                if !query.isEmpty {
                    Button {
                        query = ""
                        focus.wrappedValue = pane
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除筛选")
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))

            Menu {
                Picker("排序方式", selection: $order) {
                    ForEach(FileBrowser.Order.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()
            .help(order.rawValue)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 39)
    }
}

private struct PaneTitle<Actions: View>: View {
    let title: String
    let icon: String
    let detail: String?
    let isActive: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 14)
        .frame(height: 57)
    }
}

private struct FileNameCell: View {
    let name: String
    let isFolder: Bool

    var body: some View {
        Label {
            Text(name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: isFolder ? "folder.fill" : "doc")
                .foregroundStyle(isFolder ? Color.accentColor : Color.secondary)
        }
        .help(name)
    }
}

func formatBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

private func selectionStatus(total: Int, visible: Int, selected: Int) -> String {
    let count = total == visible ? "\(total) 项" : "\(visible) / \(total) 项"
    return selected == 0 ? count : "选中 \(selected) 项，共 \(count)"
}
