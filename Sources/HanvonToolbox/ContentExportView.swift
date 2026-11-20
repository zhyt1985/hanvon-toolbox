import AppKit
import SwiftUI
import ToolboxCore

struct ContentExportView: View {
    @Bindable var toolbox: ToolboxModel
    @Bindable var model: ContentExportModel
    @State private var confirmingScan = false
    @State private var confirmingBackup = false
    @State private var scanCurrent = false
    private var available: Bool { toolbox.contentOperationAvailable && model.activeJob == nil && !model.maintaining }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("内容导出", systemImage: "square.and.arrow.up.on.square").font(.title2.bold())
                Spacer()
                Text(toolbox.deviceInfo?.name ?? "未连接设备").foregroundStyle(.secondary)
                Text(toolbox.activeKind?.rawValue ?? "").font(.caption)
                Button("导出记录") { model.showingHistory.toggle() }
            }.padding()
            Divider()
            if model.showingHistory { history }
            else { catalog }
            Divider()
            HStack {
                if let active = toolbox.activity, model.activeJob != nil {
                    ProgressView().controlSize(.small)
                    Text(active)
                    if let progress = toolbox.progress, let total = progress.total {
                        Text("\(formatBytes(progress.completed)) / \(formatBytes(total))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("暂停导出") { toolbox.cancel() }
                } else {
                    Text("源文件只读 · 正式输出保留 SHA-256 清单").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }.padding(12)
        }
        .frame(minWidth: 850, minHeight: 540)
        .task { await model.load() }
        .sheet(isPresented: $model.showingSources) {
            ContentSourceSettingsView(toolbox: toolbox, model: model)
        }
        .alert("内容导出未完成", isPresented: Binding(get: { model.error != nil && !model.showingSources }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("读取笔记索引？", isPresented: $confirmingScan) {
            Button("只读扫描笔记库") { model.scan(toolbox, notes: true, useCurrent: scanCurrent) }
        } message: {
            Text(toolbox.activeKind == .usb && !scanCurrent
                 ? "将读取设备 notes 目录中的笔记索引，用于显示标题。不会修改设备文件；请先保存并退出笔记编辑。"
                 : "将读取当前已授权目录中的 .database/HvNote.db。请在主窗口定位到笔记库目录；当前授权不能访问的目录不会读取。")
        }
        .confirmationDialog("备份当前内容来源目录？", isPresented: $confirmingBackup) {
            Button("选择目标并备份目录") { model.export(toolbox, wholeSource: true) }
        } message: {
            Text("包含来源目录中的隐藏文件、索引和所有子目录，可能包含未选中的笔记标题与内容。仅作原始目录备份，不承诺完整资源还原或可回写恢复。请保存并退出编辑、结束录音。")
        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu("扫描笔记库") {
                    if toolbox.activeKind == .usb {
                        Button("扫描设备默认笔记库") { scanCurrent = false; confirmingScan = true }
                    }
                    Button("扫描当前位置笔记库") { scanCurrent = true; confirmingScan = true }
                }.disabled(!available || toolbox.activeKind == .wifi)
                Button("收集当前位置文件") { model.scan(toolbox, notes: false) }.disabled(!available)
                if toolbox.activeKind == .companion {
                    Button("无线来源…") { model.showingSources = true }
                        .disabled(!available || toolbox.deviceInfo?.supportsContentSources != true)
                }
                Spacer()
                TextField("筛选标题", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 250)
            }
            if toolbox.activeKind == .companion {
                Text(toolbox.deviceInfo?.supportsContentSources == true
                     ? "可从「无线来源」读取单独授权的只读目录；伴侣 0.7.0 起先准备固定副本再导出，暂停超过 24 小时需重新创建任务。"
                     : "当前位置使用原文件管理授权。伴侣 0.6.0 起支持单独授权的无线只读来源。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let catalog = model.catalog {
                Text("来源：\(catalog.source.displayName) · \(catalog.source.connection.rawValue) · 扫描于 \(catalog.scannedAt.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(catalog.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                Table(model.visible, selection: $model.selection) {
                    TableColumn("标题") { item in
                        Label(item.title, systemImage: item.protected ? "lock" : item.isDirectory ? "folder" : "doc")
                    }.width(min: 220, ideal: 370)
                    TableColumn("类型") { item in
                        Text(catalog.source.kind == .notes ? "笔记／便签未分类" : item.isDirectory ? "目录" : "来源文件")
                    }.width(min: 110, ideal: 135)
                    TableColumn("大小") { item in Text(item.byteCount.map(formatBytes) ?? "—") }.width(90)
                    TableColumn("目录修改时间") { item in
                        Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    }.width(min: 140, ideal: 160)
                }
                .frame(minHeight: 200, maxHeight: .infinity)
                HStack {
                    Button("选择当前筛选") { model.selection.formUnion(model.visible.filter { !$0.protected }.map(\.id)) }
                    Button("取消选择当前筛选") { model.selection.subtract(model.visible.map(\.id)) }
                    Text("已选 \(model.selection.count) 项" + (model.hiddenSelection > 0 ? "（筛选外 \(model.hiddenSelection) 项）" : ""))
                        .font(.caption)
                    Spacer()
                    Button("来源目录备份…") { confirmingBackup = true }.disabled(!available)
                    Button("导出所选…") { model.export(toolbox) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!available || model.selected.isEmpty || model.selected.contains(where: \.protected))
                }
            } else {
                ContentUnavailableView("选择内容来源", systemImage: "doc.on.doc",
                    description: Text("连接设备后扫描笔记索引，或在主窗口定位到 PDF、图片、音频所在目录，再收集当前位置文件。"))
            }
            Text("书信与正式录音来源、便签独立分类及原始页面转 PDF 尚未开放；已导出的文件可直接收集。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    private var history: some View {
        VStack(alignment: .leading) {
            Button("返回内容列表") { model.showingHistory = false }
            if model.jobs.isEmpty {
                ContentUnavailableView("暂无内容导出记录", systemImage: "clock")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.jobs) { job in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(job.createdAt.formatted()).font(.headline)
                                        Text(job.source.connection.rawValue).font(.caption)
                                        Spacer()
                                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([job.output]) }
                                        Button("继续／重试") { model.start(job, toolbox: toolbox) }
                                            .disabled(!available || job.rows.allSatisfy(\.state.isFinished))
                                        Button("取消未完成") { model.cancel(job, toolbox: toolbox) }
                                            .disabled(toolbox.isBusy || model.maintaining || job.rows.allSatisfy(\.state.isFinished))
                                    }
                                    ForEach(job.rows) { row in
                                        HStack(alignment: .top) {
                                            Text(row.state.label).frame(width: 100, alignment: .leading)
                                            VStack(alignment: .leading) {
                                                Text(row.item.title)
                                                if let message = row.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                                            }
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                    }
                }
            }
        }.padding()
    }
}
