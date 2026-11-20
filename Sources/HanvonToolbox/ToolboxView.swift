import AppKit
import QuickLook
import SwiftUI
import ToolboxCore

struct ToolboxView: View {
    @State private var model = ToolboxModel()
    @State private var activePane: BrowserPane = .mac
    @State private var showingSync = false
    @State private var pendingSync: SyncPreview?
    @AppStorage("hanvon.showFileInspector") private var showingInspector = true
    @FocusState private var filterFocus: BrowserPane?
    @FocusState private var tableFocus: BrowserPane?
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            HSplitView {
                LocalPane(model: model, activePane: $activePane, filterFocus: $filterFocus, tableFocus: $tableFocus)
                    .frame(minWidth: 320, idealWidth: 455)
                DevicePane(model: model, activePane: $activePane, filterFocus: $filterFocus, tableFocus: $tableFocus)
                    .frame(minWidth: 375, idealWidth: 505)
                if showingInspector {
                    FileInspector(model: model, pane: activePane, isPresented: $showingInspector)
                        .frame(minWidth: 225, idealWidth: 265, maxWidth: 290)
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: showingInspector ? 940 : 840)
        .background(.background)
        .task { model.startBrowsingIfNeeded() }
        .onChange(of: filterFocus) { _, pane in
            if let pane { activePane = pane }
        }
        .onChange(of: tableFocus) { _, pane in
            if let pane { activePane = pane }
        }
        .onChange(of: model.localSelection) { _, value in if !value.isEmpty { activePane = .mac } }
        .onChange(of: model.remoteSelection) { _, value in if !value.isEmpty { activePane = .device } }
        .sheet(item: $model.nameRequest) { request in
            NameDialog(title: request.label, initialName: request.item?.name) { name in
                model.submitName(name, for: request)
            }
        }
        .sheet(item: $model.localNameRequest) { request in
            NameDialog(title: request.label, initialName: request.item?.name) { name in
                model.submitLocalName(name, for: request)
            }
        }
        .sheet(isPresented: $showingSync, onDismiss: {
            if let pendingSync {
                self.pendingSync = nil
                model.runSync(pendingSync)
            }
            model.clearSyncPreview()
        }) {
            SyncView(model: model) { preview in
                pendingSync = preview
                showingSync = false
            }
        }
        .sheet(isPresented: $model.showingTransfers) {
            TransferHistoryView(model: model)
        }
        .sheet(isPresented: $model.showingTrash) { FileTrashView(model: model) }
        .sheet(isPresented: $model.showingSearch) { BrowserSearchView(model: model) }
        .quickLookPreview($model.previewURL)
        .sheet(isPresented: $model.showingInfo) {
            if let deviceInfo = model.deviceInfo {
                DeviceInfoView(info: deviceInfo, kind: model.activeKind)
            }
        }
        .alert("操作未完成", isPresented: errorPresented) {
            Button("好", role: .cancel) { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
        }
        .confirmationDialog(
            "将选中项目移入回收站？",
            isPresented: deletionPresented,
            presenting: model.deletionRequest
        ) { request in
            Button("回收 \(request.items.count) 项", role: .destructive) {
                model.delete(request)
                model.deletionRequest = nil
            }
            Button("取消", role: .cancel) { model.deletionRequest = nil }
        } message: { request in
            Text(request.items.count == 1
                 ? "「\(request.items[0].name)」会保留在设备回收站，可恢复到原目录。"
                 : "\(request.items.count) 个项目会保留在设备回收站，可恢复到原目录。")
        }
    }

    private var connectionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Picker("连接方式", selection: $model.mode) {
                    Text("USB").tag(ConnectionKind.usb)
                    Text("Wi-Fi 传书").tag(ConnectionKind.wifi)
                    Text("无线管理").tag(ConnectionKind.companion)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("连接方式")
                .frame(width: 248)
                .disabled(model.isBusy)
                .onChange(of: model.mode) { _, value in
                    if value == .wifi { addressFocused = true }
                    model.connectionModeChanged()
                }

                if model.mode == .wifi {
                    TextField("输入电纸书显示的局域网地址", text: $model.wifiAddress)
                        .textFieldStyle(.roundedBorder)
                        .focused($addressFocused)
                        .frame(idealWidth: 250, maxWidth: 320)
                        .disabled(model.isBusy)
                        .onSubmit { if readyToConnect { model.connect() } }
                }

                Button(connectTitle) {
                    model.connect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!readyToConnect)

                if model.isConnected {
                    Button("断开") { model.disconnect() }
                        .disabled(model.isBusy)
                }

                Spacer(minLength: 8)

                Button {
                    filterFocus = activePane == .device && model.isConnected ? .device : .mac
                } label: {
                    Label("筛选文件", systemImage: "magnifyingglass").labelStyle(.iconOnly)
                }
                .keyboardShortcut("f")
                .help("筛选当前目录")

                Button {
                    showingInspector.toggle()
                } label: {
                    Label(showingInspector ? "隐藏文件检查器" : "显示文件检查器", systemImage: "sidebar.right")
                        .labelStyle(.iconOnly)
                }
                .help(showingInspector ? "隐藏文件检查器" : "显示文件检查器")

                Button {
                    model.clearSyncPreview()
                    showingSync = true
                } label: {
                    Label("同步", systemImage: "arrow.left.arrow.right")
                }
                .disabled(model.isBusy)
                .help("比较双栏目录，预览并执行单向同步")

                Button {
                    model.showingTransfers = true
                } label: {
                    Label("传输记录", systemImage: "list.bullet.rectangle")
                }

                Button { model.openContentExport() } label: {
                    Label("内容导出", systemImage: "square.and.arrow.up.on.square").labelStyle(.iconOnly)
                }
                .help("内容导出：笔记索引、原始目录与已导出文件收集")

                Button { model.showingTrash = true } label: { Label("回收站", systemImage: "trash") }

                Button {
                    model.reloadInfo()
                } label: {
                    Label("设备信息", systemImage: "info.circle")
                }
                .disabled(!model.isConnected || model.isBusy)

                Button {
                    model.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("刷新两栏")
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isBusy)
            }
            if model.mode == .companion {
                companionBar
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.bar)
    }

    private var connectTitle: String {
        if model.mode == .companion && model.canConnectCompanion && !model.selectedIsRemembered {
            return "配对并连接"
        }
        return model.activeKind == nil ? "连接" : "重新连接"
    }

    private var companionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.manualCompanion {
                    TextField("伴侣应用显示的 HTTPS 地址", text: $model.companionAddress)
                        .focused($addressFocused)
                        .frame(minWidth: 190, maxWidth: 330)
                } else if !model.nearby.isEmpty {
                    Picker("附近设备", selection: $model.companionSelection) {
                        ForEach(model.nearby) { item in
                            Text(model.remembered.contains { $0.id == item.id } ? item.name + " · 已记住" : item.name)
                                .tag(Optional(item.id))
                        }
                    }
                    .frame(maxWidth: 340)
                } else {
                    if let device = model.preferredCompanion {
                        Text("\(device.name) · 已记住").foregroundStyle(.secondary)
                    }
                    Text(model.discoveryNote).foregroundStyle(.secondary)
                }

                if !model.manualCompanion {
                    Button("重新查找") { model.scanAgain() }
                }
                Button(model.manualCompanion ? "使用自动发现" : "手动输入地址") {
                    model.manualCompanion.toggle()
                    if model.manualCompanion {
                        addressFocused = true
                    } else {
                        model.startBrowsingIfNeeded()
                    }
                }

                if model.selectedIsRemembered && !model.manualCompanion {
                    Button("忘记此设备") { model.forgetSelected() }
                }
                Spacer()
            }

            if model.manualCompanion, let device = model.preferredCompanion {
                Toggle("使用 \(device.name) 的已保存配对", isOn: $model.useRememberedPairing)
            }

            if !model.selectedIsRemembered && (model.selectedCompanion != nil || model.manualCompanion) {
                HStack(spacing: 10) {
                    TextField("首次配对：16 位设备指纹", text: $model.companionFingerprint)
                        .frame(width: 190)
                    SecureField("8 位配对码", text: $model.companionCode)
                        .frame(width: 108)
                    Spacer()
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(model.isBusy)
        .onSubmit { if readyToConnect { model.connect() } }
    }

    private var readyToConnect: Bool {
        guard !model.isBusy else { return false }
        switch model.mode {
        case .usb: return true
        case .wifi: return !model.wifiAddress.trimmingCharacters(in: .whitespaces).isEmpty
        case .companion:
            return model.canConnectCompanion
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.secondary.opacity(0.65))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(model.activity ?? model.status)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.isBusy {
                if let progress = model.progress, let total = progress.total, total > 0 {
                    ProgressView(value: min(1, Double(progress.completed) / Double(total)))
                        .frame(width: 125)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("取消") { model.cancel() }
                    .controlSize(.small)
            } else if let activeKind = model.activeKind {
                Text(activeKind.rawValue)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(.bar)
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { model.deletionRequest != nil }, set: { if !$0 { model.deletionRequest = nil } })
    }
}

private struct NameDialog: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name: String
    let title: String
    let submit: (String) -> Void

    init(title: String, initialName: String?, submit: @escaping (String) -> Void) {
        self.title = title
        self.submit = submit
        _name = State(initialValue: initialName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("确定") {
                    dismiss()
                    submit(name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? validateFileName(name)) == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }
}

private struct DeviceInfoView: View {
    let info: DeviceInfo
    let kind: ConnectionKind?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(info.name).font(.title2.weight(.semibold))
                    if let kind {
                        Text(kind.rawValue).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 11) {
                ForEach(info.fields) { field in
                    GridRow {
                        Text(field.name).foregroundStyle(.secondary)
                        Text(field.value).textSelection(.enabled)
                    }
                }
            }
            ForEach(info.volumes) { volume in
                if let capacity = volume.capacity, let free = volume.freeSpace {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(volume.name).font(.headline)
                        if capacity > 0, free <= capacity {
                            ProgressView(value: Double(capacity - free), total: Double(capacity))
                        }
                        Text("可用 \(formatBytes(free))，总计 \(formatBytes(capacity))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if kind == .usb {
                Text("Android 版本和固件构建号需在设备的系统信息中查看。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(23)
        .frame(minWidth: 480)
    }
}
