import AppKit
import Foundation
import Observation
import SwiftUI
import ToolboxCore

@Observable @MainActor
final class ContentExportModel {
    var catalog: ContentCatalog?
    var selection = Set<String>()
    var query = ""
    var tab = "内容"
    var jobs: [ContentExportJob] = []
    var error: String?
    var activeJob: UUID?
    var showingHistory = false
    var maintaining = false
    var showingSources = false
    var sources: [CompanionContentSource] = []
    var accessRequest: CompanionContentAccessRequest?
    @ObservationIgnored private var accessPoll: Task<Void, Never>?
    private let store = ContentExportStore()
    private var loaded = false

    var visible: [ExportContentItem] {
        catalog?.items.filter { query.isEmpty || $0.title.localizedStandardContains(query) } ?? []
    }
    var selected: [ExportContentItem] { catalog?.items.filter { selection.contains($0.id) } ?? [] }
    var hiddenSelection: Int { selection.subtracting(Set(visible.map(\.id))).count }

    func load() async {
        guard !loaded else { return }; loaded = true
        do {
            let result = try await store.loadReport(); jobs = result.jobs; error = result.warning
        } catch { self.error = error.localizedDescription }
    }
    func scan(_ toolbox: ToolboxModel, notes: Bool, useCurrent: Bool = false) {
        toolbox.performContentOperation(notes ? "正在只读扫描笔记索引" : "正在扫描内容来源文件") { context, _ in
            do {
                let path = notes && context.kind == .usb && !useCurrent ? ["notes"] : context.currentPath
                let source = ContentSource(connection: context.kind, deviceScope: context.scope, path: path,
                    kind: notes ? .notes : .files, displayName: notes ? "笔记与便签" : path.last ?? context.volumeName,
                    resumeIdentity: context.identity, resumeVolume: context.volumeIdentity)
                self.catalog = try await ContentReader.scan(source, root: context.root, device: context.device)
                self.selection = []; self.query = ""; self.error = nil
            } catch {
                self.error = error.localizedDescription
                if TransferBatch.reconnectError(error) { throw error }
            }
        }
    }

    func export(_ toolbox: ToolboxModel, wholeSource: Bool = false) {
        guard let catalog else { return }
        let items: [ExportContentItem]
        if wholeSource {
            items = [.init(id: "__source__", title: catalog.source.displayName + " 来源目录备份",
                           path: [], isDirectory: true)]
        } else { items = selected }
        guard !items.isEmpty, items.count <= 500 else { error = "请选择 1 至 500 项内容，或使用来源目录备份"; return }
        let panel = NSOpenPanel()
        panel.title = "选择内容导出目标"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = toolbox.localFolder
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let job = ContentExportJob(source: catalog.source, items: items, parent: parent.resolvingSymlinksInPath())
        start(job, toolbox: toolbox)
    }

    func start(_ job: ContentExportJob, toolbox: ToolboxModel) {
        toolbox.performContentOperation("正在导出内容") { context, progress in
            let device: any DeviceConnection
            let root: DeviceFolder
            if let source = job.source.wirelessSource {
                guard context.kind == .companion, let client = context.device as? CompanionDevice,
                      job.source.deviceScope == source.binding(deviceID: context.identity) else {
                    self.error = "请连接此内容来源原来配对的电纸书"; return
                }
                device = try client.contentDevice(source); root = .companion(path: "")
            } else {
                guard context.scope == job.source.deviceScope, context.kind == job.source.connection else {
                self.error = "请连接创建任务时的原设备和原存储；不会自动跨 USB 与 Wi-Fi 切换"
                return
                }
                device = context.device; root = context.root
            }
            if let companion = device as? CompanionContentDevice {
                for previous in self.jobs where previous.source.deviceScope == job.source.deviceScope {
                    self.receive(try await ContentExporter.releaseFinishedSnapshots(previous, device: companion, store: self.store))
                }
            }
            self.activeJob = job.id; self.showingHistory = true
            defer { self.activeJob = nil }
            do {
                let result = try await ContentExporter.run(job, root: root, device: device,
                    store: self.store, progress: progress) { update in
                        await MainActor.run { self.receive(update) }
                    }
                self.receive(result)
            } catch {
                self.error = error.localizedDescription
                if TransferBatch.reconnectError(error) { throw error }
            }
        }
    }

    func loadSources(_ toolbox: ToolboxModel) {
        error = nil
        toolbox.performContentOperation("正在读取无线内容来源") { context, _ in
            guard let client = context.device as? CompanionDevice else { self.error = "请先连接无线管理"; return }
            do {
                self.sources = try await client.contentSources()
                try await self.purgeRevokedJobs(deviceID: context.identity)
                if let request = self.accessRequest, request.state == "pending", self.sources.contains(where: { $0.id == request.sourceID }) {
                    self.poll(request, client: client, deviceID: context.identity)
                } else { self.accessRequest = nil }
            } catch { self.error = error.localizedDescription }
        }
    }

    func requestAccess(_ source: CompanionContentSource, toolbox: ToolboxModel) {
        error = nil
        toolbox.performContentOperation("正在申请内容来源访问") { context, _ in
            guard let client = context.device as? CompanionDevice else { return }
            do {
                let request = try await client.requestContentAccess(source)
                self.accessRequest = request
                self.poll(request, client: client, deviceID: context.identity)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func poll(_ request: CompanionContentAccessRequest, client: CompanionDevice, deviceID: String) {
        accessPoll?.cancel()
        accessPoll = Task {
            do {
                for _ in 0..<300 {
                    try await Task.sleep(for: .seconds(2))
                    let status = try await client.contentAccessStatus(request)
                    try Task.checkCancellation()
                    accessRequest = status
                    if status.state != "pending" {
                        sources = try await client.contentSources()
                        try await purgeRevokedJobs(deviceID: deviceID)
                        return
                    }
                }
                accessRequest = nil
                error = "本次授权等待已到期，请刷新来源后重试"
            } catch {
                if !Task.isCancelled {
                    if error is ContentSourceAccessError { accessRequest = nil }
                    if case .pairingExpired? = error as? ToolboxError { accessRequest = nil }
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func stopWaitingForAccess() { accessPoll?.cancel(); accessPoll = nil }

    private func purgeRevokedJobs(deviceID: String) async throws {
        for job in jobs {
            guard let previous = job.source.wirelessSource,
                  job.source.deviceScope == previous.binding(deviceID: deviceID),
                  job.rows.contains(where: { !$0.state.isFinished }) else { continue }
            let current = sources.first { $0.id == previous.id }
            if current?.revision != previous.revision || current?.authorized != true || current?.readable != true {
                receive(try await ContentExporter.invalidateAccess(job, store: store))
            }
        }
    }

    func scanSource(_ source: CompanionContentSource, toolbox: ToolboxModel) {
        stopWaitingForAccess(); showingSources = false
        toolbox.performContentOperation("正在扫描专用只读内容来源") { context, _ in
            guard let client = context.device as? CompanionDevice else { return }
            do {
                let device = try client.contentDevice(source)
                _ = try await device.info()
                let origin = ContentSource(connection: .companion, deviceScope: source.binding(deviceID: context.identity),
                    path: [], kind: source.kind, displayName: source.name,
                    resumeIdentity: context.identity, resumeVolume: source.cacheIdentity, wirelessSource: source)
                self.catalog = try await ContentReader.scan(origin, root: .companion(path: ""), device: device)
                self.selection = []; self.query = ""; self.showingHistory = false
            } catch { self.error = error.localizedDescription }
        }
    }
    func cancel(_ job: ContentExportJob, toolbox: ToolboxModel) {
        guard !maintaining, activeJob == nil else { return }
        maintaining = true
        Task {
            defer { maintaining = false }
            do {
                let cancelled = try await ContentExporter.cancel(job, store: store)
                receive(cancelled)
                if let source = job.source.wirelessSource {
                    toolbox.performContentOperation("正在释放设备内容副本") { context, _ in
                        guard let client = context.device as? CompanionDevice,
                              job.source.deviceScope == source.binding(deviceID: context.identity) else { return }
                        self.receive(try await ContentExporter.releaseFinishedSnapshots(cancelled, device: client.contentDevice(source), store: self.store))
                    }
                }
            }
            catch { self.error = error.localizedDescription }
        }
    }
    private func receive(_ job: ContentExportJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        else { jobs.insert(job, at: 0) }
    }
}

@MainActor
final class ContentExportWindowController: NSWindowController {
    let contentModel = ContentExportModel()
    init(toolbox: ToolboxModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1010, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "内容导出"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hosting = NSHostingView(rootView: ContentExportView(toolbox: toolbox, model: contentModel))
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.minSize = NSSize(width: 850, height: 540)
        window.setContentSize(NSSize(width: 1010, height: 680))
        window.center()
    }
    required init?(coder: NSCoder) { nil }
}
