import SwiftUI
import ToolboxCore

struct ContentSourceSettingsView: View {
    let toolbox: ToolboxModel
    @Bindable var model: ContentExportModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSourceID: String?
    private var selectedSource: CompanionContentSource? { model.sources.first { $0.id == selectedSourceID } }
    private var connected: Bool { toolbox.isConnected && toolbox.activeKind == .companion }
    private var available: Bool { connected && toolbox.contentOperationAvailable }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("无线内容来源").font(.title2.bold())
                Spacer()
                Button("刷新来源") { model.loadSources(toolbox) }.disabled(!available)
                Button("完成") { dismiss() }
            }
            Text("先在电纸书伴侣中添加只读来源。已有配对不会自动获得新增目录权限；申请后请核对两端显示的六位请求编号，并在电纸书确认。")
                .foregroundStyle(.secondary)
            if !connected {
                Label("电纸书暂离线，尚未核对当前来源和授权。下方仅为上次读取的结果；连接恢复后请刷新来源。", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary).font(.callout)
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if let request = model.accessRequest {
                GroupBox {
                    VStack(alignment: .leading) {
                        Text("请求编号 " + request.code).font(.title2.monospacedDigit()).textSelection(.enabled)
                        Text(request.state == "pending" ? "等待电纸书确认，只读访问尚未开放"
                             : request.state == "approved" ? "设备已确认，可扫描该来源" : "设备已拒绝本次请求")
                        if request.state == "pending" {
                            Button("停止等待") { model.stopWaitingForAccess(); model.accessRequest = nil }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if model.sources.isEmpty {
                ContentUnavailableView(connected ? "尚无内容来源" : "等待连接电纸书", systemImage: connected ? "folder.badge.plus" : "wifi.slash",
                    description: Text(connected ? "在电纸书点「添加笔记来源」或「添加文件收集来源」。无需修改现有共享目录。" : "连接恢复后刷新，查看当前来源及授权。"))
            } else {
                List(model.sources, selection: $selectedSourceID) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.name).font(.headline).lineLimit(2)
                            Text((connected ? "" : "上次读取 · ") + (source.kind == .notes ? "笔记库" : "文件收集") + " · " +
                                 (!source.readable ? "系统目录权限失效" : source.authorized ? "已允许此 Mac 只读" : "等待单独授权"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(.vertical, 7).tag(source.id)
                }
                .frame(minHeight: 200)
                HStack {
                    Text("选择来源后操作").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let source = selectedSource {
                        if source.authorized {
                            Button(source.kind == .notes ? "扫描笔记" : "浏览来源") {
                                model.scanSource(source, toolbox: toolbox)
                            }.disabled(!available || !source.readable)
                        } else {
                            Button("申请只读访问") { model.requestAccess(source, toolbox: toolbox) }
                                .disabled(!available || !source.readable || model.accessRequest?.state == "pending")
                        }
                    }
                }
            }
            Text("请先保存笔记并结束录音，再开始导出。撤销或移除来源请在电纸书操作；原文件管理授权保持不变。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(minWidth: 680, idealWidth: 740, minHeight: 440)
        .task { model.loadSources(toolbox) }
        .onChange(of: model.sources) { _, sources in
            if !sources.contains(where: { $0.id == selectedSourceID }) { selectedSourceID = sources.first?.id }
        }
        .onAppear { selectedSourceID = model.sources.first?.id }
        .onDisappear { model.stopWaitingForAccess() }
    }
}
