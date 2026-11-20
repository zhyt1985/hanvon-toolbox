import AppKit
import Foundation
import Observation
import os
import ToolboxCore
import UniformTypeIdentifiers

struct LocalItem: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let isFolder: Bool
    let size: Int?
    let modified: Date?
    var name: String { url.lastPathComponent }
}

struct Breadcrumb: Identifiable, Equatable, Sendable {
    let name: String
    let folder: DeviceFolder
    var id: DeviceFolder { folder }
}

struct NameRequest: Identifiable {
    let id = UUID()
    let item: DeviceItem?

    var label: String { item == nil ? "新建文件夹" : "重命名" }
}

struct DeletionRequest: Identifiable {
    let id = UUID()
    let items: [DeviceItem]
}

struct LocalNameRequest: Identifiable, Sendable {
    let id = UUID()
    let directory: URL
    let item: LocalItem?

    var label: String { item == nil ? "在 Mac 上新建文件夹" : "在 Mac 上重命名" }
}

private struct PendingRelocation {
    let items: [DeviceItem]
    let copying: Bool
}

@Observable @MainActor
final class ToolboxModel {
    var mode = ConnectionKind.usb
    private(set) var nearby: [DiscoveredCompanion] = []
    private(set) var remembered = RememberedCompanion.load()
    private(set) var discoveryNote = "正在查找附近的电纸书…"
    var companionSelection: String?
    var manualCompanion = false
    var useRememberedPairing = true
    private var preferredID = UserDefaults.standard.string(forKey: "hanvon.preferredCompanion")
    var wifiAddress = UserDefaults.standard.string(forKey: "hanvon.wifiAddress") ?? ""
    var companionAddress = UserDefaults.standard.string(forKey: "hanvon.companionAddress") ?? ""
    var companionFingerprint = ""
    var companionCode = ""
    var localFolder = FileManager.default.homeDirectoryForCurrentUser
    private(set) var localItems: [LocalItem] = []
    var localSelection: Set<URL> = []
    private(set) var remoteItems: [DeviceItem] = []
    var remoteSelection: Set<DeviceItem.ID> = []
    private(set) var remotePath: [Breadcrumb] = []
    private(set) var deviceInfo: DeviceInfo?
    private(set) var activeKind: ConnectionKind?
    private(set) var activity: String?
    private(set) var progress: TransferProgress?
    private(set) var status = "选择 USB 或 Wi-Fi 连接电纸书"
    var errorText: String?
    var nameRequest: NameRequest?
    var localNameRequest: LocalNameRequest?
    private(set) var changingLocalName = false
    var deletionRequest: DeletionRequest?
    var showingInfo = false
    var showingTransfers = false
    var showingTrash = false
    private(set) var localTrash: [LocalTrashRecord] = []
    private(set) var deviceTrash: [DeviceTrashRecord] = []
    private(set) var activeBatchID: UUID?
    private(set) var activeRowID: UUID?
    private(set) var transferRate: Double?
    private(set) var transferRemaining: Double?
    @ObservationIgnored private var rowOperation: Task<Void, Error>?
    private var cancelledRows = Set<UUID>()
    private var rateSample: (time: Double, bytes: UInt64)?
    private(set) var localNavigation = BrowserNavigation<URL>()
    private(set) var remoteNavigation = BrowserNavigation<[Breadcrumb]>()
    private(set) var bookmarks = BrowserBookmark.load()
    var previewURL: URL?
    private var previewCache: URL?
    var showingSearch = false
    var searchOnDevice = false
    var searchQuery = ""
    private(set) var searchHits: [BrowserSearchHit] = []
    private var searchSession: String?
    private(set) var transferHistory: [TransferRecord] = []
    private(set) var transferHistoryWarning: String?
    private(set) var syncPreview: SyncPreview?
    private(set) var syncError: String?
    private(set) var comparingDirectories = false
    private(set) var verifyingSyncContents = false
    private(set) var syncPresets: [SyncPreset] = []
    private(set) var syncPresetStorageError: String?
    private(set) var syncBackups: [SyncBackup] = []
    private(set) var syncBackupError: String?
    private(set) var syncBackupFileBytes: [UUID: UInt64] = [:]
    private(set) var deviceRecoveryCopies: [SyncBackup] = []

    @ObservationIgnored private let historyStore: TransferHistoryStore
    @ObservationIgnored private let syncPresetStore = SyncPresetStore()
    @ObservationIgnored private let syncBaselineStore = SyncBaselineStore()
    @ObservationIgnored private let launchID = UUID()
    @ObservationIgnored private let discovery = CompanionDiscovery()
    @ObservationIgnored private var connectionTarget: DiscoveredCompanion?
    @ObservationIgnored private var lastCompanionAddress = UserDefaults.standard.string(forKey: "hanvon.companionAddress") ?? ""
    @ObservationIgnored private var autoConnectSuppressed = false
    @ObservationIgnored private var retry = CompanionRetry()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var localLoad: Task<Void, Never>?
    private var localLoadTarget: URL?
    @ObservationIgnored private var sessionIdentity = UUID().uuidString
    @ObservationIgnored private var activityID: UUID?
    @ObservationIgnored private var device: (any DeviceConnection)?
    @ObservationIgnored private var contentExportWindow: ContentExportWindowController?
    private var relocation: PendingRelocation?

    var isBusy: Bool { activity != nil }
    var supportsByteResume: Bool { deviceInfo?.supportsResumableTransfers == true }
    var locations: [DeviceVolume] { deviceInfo?.volumes ?? [] }
    var currentRemoteFolder: DeviceFolder? { remotePath.last?.folder }
    var isConnected: Bool { deviceInfo != nil }
    var canManage: Bool { deviceInfo?.canManageFiles == true && !isBusy }
    var canSendAPK: Bool { deviceInfo?.supportsAPK == true && !isBusy }
    var canCopyAndDelete: Bool { canManage && (activeKind == .usb || deviceInfo?.supportsFileOperations == true) }
    var canPaste: Bool { relocation != nil && canManage && currentRemoteFolder != nil }
    var contentOperationAvailable: Bool { isConnected && !isBusy }

    func openContentExport() {
        if contentExportWindow == nil { contentExportWindow = ContentExportWindowController(toolbox: self) }
        contentExportWindow?.showWindow(nil)
        contentExportWindow?.window?.makeKeyAndOrderFront(nil)
    }

    struct ContentConnectionContext: Sendable {
        let device: any DeviceConnection
        let root: DeviceFolder
        let kind: ConnectionKind
        let scope: String
        let currentPath: [String]
        let volumeName: String
        let identity: String
        let volumeIdentity: String?
    }

    func performContentOperation(_ label: String,
        work: @escaping @MainActor (ContentConnectionContext, @escaping ProgressUpdate) async throws -> Void) {
        guard !isBusy, let device, let kind = activeKind, let root = remotePath.first?.folder,
              let target = transferDestination(root: root) else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let scope = try? encoder.encode(target).base64EncodedString() else { return }
        let context = ContentConnectionContext(device: device, root: root, kind: kind, scope: scope,
            currentPath: remotePath.dropFirst().map(\.name), volumeName: target.volumeName,
            identity: target.identity, volumeIdentity: target.volumeIdentity)
        perform(label) { progress in try await work(context, progress) }
    }
    var canOpenSyncPreset: Bool { !isBusy && localLoadTarget == nil && !changingLocalName }
    var canCompareDirectories: Bool {
        canManage && localLoadTarget == nil && !changingLocalName && currentRemoteFolder != nil
            && (activeKind == .usb || activeKind == .companion)
    }
    var canSaveSyncPreset: Bool {
        guard canCompareDirectories, syncPresetStorageError == nil, let root = remotePath.first?.folder,
              let target = transferDestination(root: root) else { return false }
        return target.launchID == nil
    }
    var browsableRemoteItems: [DeviceItem] { remoteItems.filter { !SyncBackup.isWorkingFile($0.name) && $0.name != DeviceTrashStore.folderName } }
    var selectedRemoteItems: [DeviceItem] { browsableRemoteItems.filter { remoteSelection.contains($0.id) } }
    var selectedLocalItems: [LocalItem] { localItems.filter { localSelection.contains($0.id) } }

    var selectedCompanion: DiscoveredCompanion? {
        if manualCompanion { return nil }
        return nearby.first { $0.id == companionSelection }
    }

    var selectedIsRemembered: Bool {
        rememberedSelection != nil
    }

    var preferredCompanion: RememberedCompanion? {
        remembered.first { $0.id == preferredID }
    }

    private var rememberedSelection: DiscoveredCompanion? {
        if manualCompanion {
            guard useRememberedPairing, let preferredCompanion else { return nil }
            return .init(id: preferredCompanion.id, name: preferredCompanion.name, address: companionAddress)
        }
        if let selectedCompanion {
            return remembered.contains { $0.id == selectedCompanion.id } ? selectedCompanion : nil
        }
        return savedCompanion
    }

    private var savedCompanion: DiscoveredCompanion? {
        guard let preferredCompanion, !lastCompanionAddress.isEmpty else { return nil }
        return .init(id: preferredCompanion.id, name: preferredCompanion.name, address: lastCompanionAddress)
    }

    var canConnectCompanion: Bool {
        if let rememberedSelection {
            return !rememberedSelection.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasAddress = manualCompanion ? !companionAddress.isEmpty : selectedCompanion != nil
        return hasAddress && !companionFingerprint.isEmpty && !companionCode.isEmpty
    }

    init(historyStore: TransferHistoryStore = TransferHistoryStore()) {
        self.historyStore = historyStore
        let history = historyStore.load()
        transferHistory = history.records
        transferHistoryWarning = history.warning
        do {
            syncPresets = try syncPresetStore.load()
        } catch {
            syncPresetStorageError = "无法读取已保存的同步预设。"
        }
        mode = preferredID == nil ? .usb : .companion
        discovery.onChange = { [weak self] devices in self?.discovered(devices) }
        discovery.onError = { [weak self] error in self?.discoveryNote = error }
        openLocal(localFolder)
    }

    func startBrowsingIfNeeded() {
        guard mode == .companion else {
            retryTask?.cancel()
            retryTask = nil
            discovery.stop()
            return
        }
        if let host = URL(string: lastCompanionAddress)?.host {
            discovery.knownHosts = [host]
        }
        discovery.start()
        alignCompanion()
    }

    func connectionModeChanged() {
        guard let activeKind, activeKind != mode else {
            startBrowsingIfNeeded()
            return
        }
        perform("正在切换连接方式") { _ in
            await self.resetConnection()
            self.status = self.mode == .companion ? "等待电纸书开启无线管理" : "请选择连接"
            self.startBrowsingIfNeeded()
        }
    }

    func scanAgain() {
        discoveryNote = "正在查找附近的电纸书…"
        retry = CompanionRetry()
        if activeKind != .companion { discovery.stop() }
        discovery.start()
        alignCompanion()
    }

    private func discovered(_ devices: [DiscoveredCompanion]) {
        nearby = devices
        if !devices.contains(where: { $0.id == companionSelection }) {
            companionSelection = devices.first(where: { $0.id == preferredID })?.id ?? devices.first?.id
        }
        discoveryNote = devices.isEmpty ? "正在查找附近的电纸书…" : "找到 \(devices.count) 台电纸书"
        alignCompanion()
    }

    private func alignCompanion() {
        retryTask?.cancel()
        retryTask = nil
        guard mode == .companion, !manualCompanion, !autoConnectSuppressed, !isBusy,
              !isConnected, let preferredCompanion,
              let target = nearby.first(where: { $0.id == preferredCompanion.id }) ?? savedCompanion else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if retry.waiting(for: target, now: now) {
            if let deadline = retry.deadline {
                retryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, deadline - now)))
                    guard !Task.isCancelled else { return }
                    self?.alignCompanion()
                }
            }
            return
        }
        if nearby.contains(where: { $0.id == target.id }) { companionSelection = target.id }
        reconnect(to: target, automatic: true)
    }

    func connect() {
        if mode == .companion {
            autoConnectSuppressed = false
            retry = CompanionRetry()
            if let target = rememberedSelection {
                reconnect(to: target, automatic: false)
            } else {
                pairSelected()
            }
            return
        }

        let mode = self.mode
        let address = wifiAddress
        perform("正在连接 \(mode.rawValue)") { _ in
            await self.resetConnection()
            let opened: any DeviceConnection
            if mode == .usb {
                opened = try await USBDevice.connect()
            } else {
                opened = try await WiFiDevice.connect(address: address)
            }
            _ = try await self.showConnection(opened)
            self.status = "\(mode.rawValue) 已连接"
            if mode == .wifi { UserDefaults.standard.set(address, forKey: "hanvon.wifiAddress") }
        }
    }

    private func pairSelected() {
        let target = selectedCompanion
        let address = target?.address ?? companionAddress
        let fingerprint = companionFingerprint
        let code = companionCode
        perform("正在配对") { _ in
            await self.resetConnection()
            let (opened, credentials) = try await CompanionDevice.pair(
                address: address, fingerprint: fingerprint, code: code, discoveredID: target?.id
            )
            let info = try await self.showConnection(opened)
            self.connectionTarget = DiscoveredCompanion(id: credentials.deviceID, name: info.name, address: address)
            self.watchCompanion(opened)
            self.companionCode = ""
            self.companionFingerprint = ""
            do {
                try await PairingKeychain.save(credentials)
            } catch {
                self.status = "无线管理已连接，未能记住此设备"
                self.errorText = error.localizedDescription
                return
            }
            self.remembered.removeAll { $0.id == credentials.deviceID }
            self.remembered.append(RememberedCompanion(id: credentials.deviceID, name: info.name))
            RememberedCompanion.save(self.remembered)
            self.recordCompanionAddress(address)
            self.prefer(credentials.deviceID)
            self.status = "无线管理已连接，已记住设备"
            self.manualCompanion = false
        }
    }

    private func reconnect(to target: DiscoveredCompanion, automatic: Bool) {
        perform(automatic ? "正在自动重连电纸书" : "正在重连电纸书") { _ in
            await self.resetConnection()
            do {
                let credentials = try await PairingKeychain.read(target.id)
                let opened = try await CompanionDevice.reconnect(address: target.address, credentials: credentials)
                _ = try await self.showConnection(opened, restoreCompanion: target.id)
                self.connectionTarget = target
                self.rememberCompanionFolder()
                self.retry = CompanionRetry()
                self.recordCompanionAddress(target.address)
                self.prefer(target.id)
                self.manualCompanion = false
                self.watchCompanion(opened)
                self.status = automatic ? "无线管理已自动重连" : "无线管理已连接"
            } catch ToolboxError.pairingExpired {
                try? await PairingKeychain.remove(target.id)
                self.forgetMetadata(target.id)
                self.status = "配对已失效，请重新配对"
            } catch is PairingKeychain.AuthorizationRequired {
                self.autoConnectSuppressed = true
                self.status = "钥匙串未授权，请点连接后检查系统提示"
            } catch {
                let retryable = !Task.isCancelled && TransferBatch.reconnectError(error)
                self.retry.failed(target, now: ProcessInfo.processInfo.systemUptime, retryable: retryable)
                if Task.isCancelled {
                    if automatic { self.autoConnectSuppressed = true }
                    throw error
                }
                if !automatic { throw error }
                self.status = retryable ? "电纸书暂离线，正在等待自动重连" : error.localizedDescription
            }
        }
    }

    private func watchCompanion(_ companion: CompanionDevice) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self else { return }
                guard self.mode == .companion, !self.isBusy else { continue }
                do {
                    try await companion.checkAvailability()
                } catch {
                    guard !Task.isCancelled, !self.isBusy else { continue }
                    switch error {
                    case ToolboxError.wirelessIdentityMismatch:
                        break
                    default:
                        guard TransferBatch.reconnectError(error) else { continue }
                    }
                    self.perform("正在恢复无线连接") { _ in
                        await self.handleCompanionInterruption(error)
                    }
                    return
                }
            }
        }
    }

    private func handleCompanionInterruption(_ error: any Error) async {
        let target = connectionTarget
        await resetConnection()
        retry = CompanionRetry()
        if case ToolboxError.pairingExpired = error, let target {
            try? await PairingKeychain.remove(target.id)
            forgetMetadata(target.id)
            status = "配对已失效，请重新配对"
        } else {
            status = "无线连接已中断，等待自动重连"
        }
    }

    private func showConnection(_ opened: any DeviceConnection, restoreCompanion: String? = nil) async throws -> DeviceInfo {
        do {
            let info = try await opened.info()
            guard let root = info.volumes.first else {
                throw ToolboxError.message("设备未公开可访问目录。")
            }
            let saved = remembered.first { $0.id == restoreCompanion }?.browseLocation
            let listing = try await CompanionBrowseLocation.resolve(saved, in: root) { folder in
                try await opened.list(folder)
            }
            device = opened
            sessionIdentity = UUID().uuidString
            activeKind = opened.kind
            deviceInfo = info
            remotePath = listing.path
            remoteNavigation = BrowserNavigation()
            remoteNavigation.visit(listing.path)
            remoteItems = listing.items
            return info
        } catch {
            await opened.close()
            throw error
        }
    }

    private func rememberCompanionFolder() {
        guard let target = connectionTarget,
              let index = remembered.firstIndex(where: { $0.id == target.id }),
              let first = remotePath.first,
              let identity = locations.first(where: { $0.root == first.folder })?.identity else { return }
        let location = CompanionBrowseLocation(rootIdentity: identity, names: remotePath.dropFirst().map(\.name))
        guard remembered[index].browseLocation != location else { return }
        remembered[index].browseLocation = location
        RememberedCompanion.save(remembered)
    }

    func forgetSelected() {
        guard !manualCompanion, let id = rememberedSelection?.id else { return }
        autoConnectSuppressed = true
        perform("正在清除本机配对记录") { _ in
            try await PairingKeychain.remove(id)
            if self.connectionTarget?.id == id { await self.resetConnection() }
            self.forgetMetadata(id)
            self.status = "已移除本机配对记录"
        }
    }

    private func forgetMetadata(_ id: String) {
        remembered.removeAll { $0.id == id }
        RememberedCompanion.save(remembered)
        if preferredID == id {
            preferredID = nil
            UserDefaults.standard.removeObject(forKey: "hanvon.preferredCompanion")
        }
    }

    private func recordCompanionAddress(_ address: String) {
        companionAddress = address
        lastCompanionAddress = address
        UserDefaults.standard.set(address, forKey: "hanvon.companionAddress")
        if let host = URL(string: address)?.host {
            discovery.knownHosts = [host]
        }
    }

    private func prefer(_ id: String) {
        preferredID = id
        UserDefaults.standard.set(id, forKey: "hanvon.preferredCompanion")
    }

    func disconnect() {
        if activeKind == .companion { autoConnectSuppressed = true }
        perform("正在断开") { _ in
            await self.resetConnection()
            self.status = "设备已断开"
        }
    }

    func refresh() {
        openLocal(localFolder, preserveSelection: true)
        guard let device, let folder = currentRemoteFolder else { return }
        perform("刷新设备目录") { _ in
            try await self.refreshRemote(device, folder)
            self.status = "设备目录已刷新"
        }
    }

    func reloadInfo() {
        guard let device else { return }
        perform("读取设备信息") { _ in
            self.deviceInfo = try await device.info()
            self.showingInfo = true
        }
    }

    func openLocal(_ folder: URL, preserveSelection: Bool = false, recordHistory: Bool = true, historyOffset: Int = 0) {
        localLoad?.cancel()
        localLoadTarget = folder
        localLoad = Task { [weak self] in
            do {
                let items = try await Self.readLocal(folder)
                guard !Task.isCancelled, let self else { return }
                localItems = items
                localFolder = folder
                if historyOffset == -1 { _ = localNavigation.back() }
                else if historyOffset == 1 { _ = localNavigation.forward() }
                else if recordHistory { localNavigation.visit(folder) }
                localSelection = preserveSelection ? localSelection.intersection(items.map(\.id)) : []
                localLoad = nil
                localLoadTarget = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                localLoad = nil
                localLoadTarget = nil
                errorText = error.localizedDescription
            }
        }
    }

    private nonisolated static func readLocal(_ directory: URL) async throws -> [LocalItem] {
        try await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )
            return files.compactMap { file -> LocalItem? in
                guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
                return LocalItem(url: file, isFolder: values.isDirectory == true && values.isSymbolicLink != true,
                                 size: values.fileSize, modified: values.contentModificationDate)
            }.sorted { left, right in
                if left.isFolder != right.isFolder { return left.isFolder }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }.value
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 Mac 文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = localFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        openLocal(folder)
    }

    func openLocalSelection(_ ids: Set<URL>) {
        guard ids.count == 1, let item = localItems.first(where: { ids.contains($0.id) }) else { return }
        if item.isFolder {
            openLocal(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func requestLocalName(for item: LocalItem? = nil) {
        guard !changingLocalName else { return }
        localNameRequest = LocalNameRequest(directory: localFolder, item: item)
    }

    func submitLocalName(_ name: String, for request: LocalNameRequest) {
        guard !changingLocalName, name != request.item?.name else { return }
        changingLocalName = true
        Task {
            defer { changingLocalName = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try validateFileName(name)
                    let destination = request.directory.appendingPathComponent(name)
                    if let item = request.item {
                        try FileManager.default.moveItem(at: item.url, to: destination)
                    } else {
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    }
                }.value
                if (localLoadTarget ?? localFolder) == request.directory {
                    openLocal(request.directory, preserveSelection: true)
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func openRemoteSelection(_ ids: Set<DeviceItem.ID>) {
        let items = remoteItems.filter { ids.contains($0.id) }
        guard items.count == 1, let item = items.first else { return }
        if let folder = item.folder {
            navigate(remotePath + [.init(name: item.name, folder: folder)])
        } else {
            download(items)
        }
    }

    func openVolume(_ volume: DeviceVolume) {
        navigate([.init(name: volume.name, folder: volume.root)])
    }

    func goUp() {
        guard remotePath.count > 1 else { return }
        navigate(Array(remotePath.dropLast()))
    }

    func navigate(_ path: [Breadcrumb], recordHistory: Bool = true, historyOffset: Int = 0) {
        guard let device, let folder = path.last?.folder else { return }
        perform("读取设备目录") { _ in
            let list = try await device.list(folder)
            self.remotePath = path
            if historyOffset == -1 { _ = self.remoteNavigation.back() }
            else if historyOffset == 1 { _ = self.remoteNavigation.forward() }
            else if recordHistory { self.remoteNavigation.visit(path) }
            self.rememberCompanionFolder()
            self.remoteItems = list
            self.remoteSelection = []
            self.status = "已读取 \(list.count) 项"
        }
    }

    func upload(_ files: [URL], startImmediately: Bool = true) {
        guard let device, let root = remotePath.first?.folder,
              let target = transferDestination(root: root), !files.isEmpty else { return }
        let path = remotePath.dropFirst().map(\.name)
        let title = device.kind == .wifi ? "Wi-Fi 传书上传" : "上传到电纸书"
        if !startImmediately {
            Task {
                do {
                    let steps = try await TransferBatch.planUpload(files, kind: device.kind)
                    guard self.transferDestination(root: root) == target else { throw ToolboxError.message("连接已变化，请重新加入队列") }
                    _ = await self.addBatch(title: title, target: target, path: path, steps: steps, paused: true)
                    self.status = "已加入暂停队列，可排序后开始"
                } catch { self.errorText = error.localizedDescription }
            }
            return
        }
        perform("正在准备上传") { progress in
            let steps = try await TransferBatch.planUpload(files, kind: device.kind)
            try Task.checkCancellation()
            let batch = await self.addBatch(title: title, target: target, path: path, steps: steps)
            await self.runBatch(batch, device: device, progress: progress)
        }
    }

    func chooseUpload() {
        guard let activeKind else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要发送的文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = activeKind != .wifi
        panel.allowsMultipleSelection = true
        panel.directoryURL = localFolder
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    func download(_ items: [DeviceItem], startImmediately: Bool = true) {
        guard let device, let root = remotePath.first?.folder,
              let target = transferDestination(root: root), !items.isEmpty else { return }
        let destination = localFolder
        let path = remotePath.dropFirst().map(\.name)
        if !startImmediately {
            Task {
                do {
                    let steps = try await TransferBatch.planDownload(items, device: device)
                    guard self.transferDestination(root: root) == target else { throw ToolboxError.message("连接已变化，请重新加入队列") }
                    _ = await self.addBatch(title: "下载到 Mac", target: target, path: path, local: destination, steps: steps, paused: true)
                    self.status = "已加入暂停队列，可排序后开始"
                } catch { self.errorText = error.localizedDescription }
            }
            return
        }
        perform("正在准备下载") { progress in
            let steps = try await TransferBatch.planDownload(items, device: device)
            try Task.checkCancellation()
            let batch = await self.addBatch(title: "下载到 Mac", target: target, path: path, local: destination, steps: steps)
            await self.runBatch(batch, device: device, progress: progress)
        }
    }

    func clearSyncPreview() {
        syncPreview = nil
        syncError = nil
    }

    func saveSyncPreset(named proposedName: String, direction: DirectorySync.Direction) throws {
        guard canSaveSyncPreset, let root = remotePath.first?.folder,
              let target = transferDestination(root: root) else {
            throw ToolboxError.message("请先连接可识别的设备并打开要保存的目录。")
        }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else {
            throw ToolboxError.message("请输入 1 到 60 个字符的预设名称。")
        }
        guard !syncPresets.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw ToolboxError.message("已有名为「\(name)」的预设，请换一个名称。")
        }
        let preset = SyncPreset(name: name, local: try .init(localFolder), target: target,
                                remotePath: remotePath.dropFirst().map(\.name), direction: direction)
        try saveSyncPresets(syncPresets + [preset])
    }

    func removeSyncPreset(_ id: UUID) throws {
        try syncBaselineStore.remove(for: id)
        try saveSyncPresets(syncPresets.filter { $0.id != id })
        if syncPreview?.presetID == id { clearSyncPreview() }
    }

    private func saveSyncPresets(_ presets: [SyncPreset]) throws {
        try syncPresetStore.save(presets)
        syncPresets = presets
    }

    func openSyncPreset(_ preset: SyncPreset) {
        guard canOpenSyncPreset else { return }
        clearSyncPreview()
        guard deviceInfo?.canManageFiles == true, let device,
              let volume = locations.first(where: { $0.root == preset.target.root }),
              preset.matches(transferDestination(root: volume.root)) else {
            syncError = "请通过\(preset.target.connection.rawValue)连接此预设的原设备和存储。"
            return
        }
        let session = sessionIdentity
        prepareSyncPreview {
            try preset.local.validate()
            let baseline = try self.syncBaselineStore.load(for: preset.id)
            let location = try await preset.resolve(in: volume) { try await device.list($0) }
            guard let remoteFolder = location.path.last?.folder else {
                throw ToolboxError.message("预设中的设备目录不可用。")
            }
            let rows = try await DirectorySync.compare(preset.direction, local: preset.local,
                                                       remote: remoteFolder, on: device, baseline: baseline)
            let localItems = try await Self.readLocal(preset.local.url)
            let remoteItems = try await device.list(remoteFolder)
            try Task.checkCancellation()
            try preset.local.validate()
            self.localFolder = preset.local.url
            self.localNavigation.visit(preset.local.url)
            self.localItems = localItems
            self.localSelection = []
            self.remotePath = location.path
            self.remoteNavigation.visit(location.path)
            self.remoteItems = remoteItems
            self.remoteSelection = []
            self.rememberCompanionFolder()
            return SyncPreview(direction: preset.direction, local: preset.local, target: preset.target,
                               path: location.path.map(\.name), folder: remoteFolder, session: session, rows: rows,
                               presetID: preset.id, baselineCount: baseline.count, bidirectionalPlan: nil)
        }
    }

    func compareDirectories(_ direction: DirectorySync.Direction, verifyContents: Bool = false,
                            bidirectional: Bool = false) {
        guard canCompareDirectories, let device, let root = remotePath.first?.folder,
              let folder = currentRemoteFolder, let target = transferDestination(root: root) else { return }
        let previous = syncPreview
        if bidirectional, previous?.presetID == nil { return }
        if verifyContents || previous?.presetID != nil {
            guard let previous, (!verifyContents || previous.direction == direction), syncScopeMatches(previous) else {
                syncError = "连接或目录已改变，请重新打开同步预设。"
                return
            }
        }
        if verifyContents || previous?.presetID != nil {
            syncError = nil
        } else {
            clearSyncPreview()
        }
        let local = localFolder
        let path = remotePath.map(\.name)
        let session = sessionIdentity
        prepareSyncPreview(verifyContents: verifyContents) {
            let localRoot = try DirectorySync.LocalRoot(local)
            if let previous, verifyContents || previous.presetID != nil, previous.local != localRoot {
                throw ToolboxError.message("Mac 同步目录已改变，请重新比较。")
            }
            let presetID = previous?.presetID
            let baseline = try presetID.map { try self.syncBaselineStore.load(for: $0) } ?? [:]
            let rows: [DirectorySync.Row]
            let plan: [DirectorySync.PlanRow]?
            if bidirectional {
                let comparison = try await DirectorySync.planBidirectional(local: localRoot, remote: folder,
                                                                            on: device, baseline: baseline)
                rows = comparison.verifiedFiles
                plan = comparison.rows
            } else {
                rows = try await DirectorySync.compare(direction, local: localRoot, remote: folder, on: device,
                                                       verifyContents: verifyContents, baseline: baseline)
                plan = nil
            }
            try Task.checkCancellation()
            try localRoot.validate()
            var baselineCount = presetID == nil ? nil : baseline.count
            if verifyContents, let presetID {
                let recorded = try self.syncBaselineStore.recordMatches(rows, previous: baseline, for: presetID)
                baselineCount = recorded.count
            }
            return SyncPreview(direction: direction, local: localRoot, target: target, path: path,
                               folder: folder, session: session, rows: rows,
                               presetID: presetID, baselineCount: baselineCount, bidirectionalPlan: plan)
        }
    }

    private func prepareSyncPreview(verifyContents: Bool = false, work: @escaping @MainActor () async throws -> SyncPreview) {
        comparingDirectories = true
        verifyingSyncContents = verifyContents
        perform(verifyContents ? "正在核对文件内容" : "正在比较目录") { _ in
            defer {
                self.comparingDirectories = false
                self.verifyingSyncContents = false
            }
            do {
                let preview = try await work()
                try Task.checkCancellation()
                self.syncPreview = preview
                self.status = verifyContents ? "文件内容核对完成" : "目录比较完成"
            } catch {
                if !Task.isCancelled {
                    self.syncError = error.localizedDescription
                    if TransferBatch.reconnectError(error) { throw error }
                    self.status = verifyContents ? "文件内容核对未完成" : "目录比较未完成"
                } else {
                    self.status = verifyContents ? "文件内容核对已取消" : "目录比较已取消"
                }
            }
        }
    }

    func syncScopeMatches(_ preview: SyncPreview) -> Bool {
        sessionIdentity == preview.session && currentRemoteFolder == preview.folder
            && remotePath.map(\.name) == preview.path && localFolder == preview.local.url
            && transferDestination(root: preview.target.root) == preview.target
    }

    func runSync(_ preview: SyncPreview) {
        guard canCompareDirectories, let device, syncScopeMatches(preview) else {
            errorText = "连接或目录已改变，请重新比较。"
            return
        }
        let steps: [TransferStep]
        let skipped: [TransferRecord.Row]
        let scope: SyncBackupScope?
        do {
            if let plan = preview.bidirectionalPlan {
                let selected = preview.selectedPlanRows ?? []
                let resolved = plan.map { $0.resolving(preview.planResolutions[$0.id]) }
                steps = resolved.filter { selected.contains($0.id) }.compactMap(\.step)
                skipped = resolved.filter { $0.action == .review || ($0.step != nil && !selected.contains($0.id)) }.map {
                    .init(step: .init(name: $0.path, action: .syncConflict),
                          result: .skipped($0.action == .review ? $0.detail ?? "需处理" : "未选择此项"))
                }
                scope = try backupScope(target: preview.target, local: preview.local,
                                        remotePath: Array(preview.path.dropFirst()))
            } else {
                steps = preview.rows.compactMap(\.step)
                skipped = preview.rows.compactMap { TransferRecord.Row(syncConflict: $0) }
                scope = nil
            }
        } catch {
            errorText = error.localizedDescription
            return
        }
        guard !steps.isEmpty else { return }
        perform("正在准备同步") { progress in
            try preview.local.validate()
            let title = preview.bidirectionalPlan == nil ? "单向同步 · \(preview.direction.title)" : "双向同步"
            let destination = preview.direction == .toMac || scope != nil ? preview.local.url : nil
            let batch = await self.addBatch(title: title, target: preview.target, path: Array(preview.path.dropFirst()),
                                            local: destination, syncRoot: preview.local, backupScope: scope,
                                            steps: steps, skipped: skipped)
            await self.runBatch(batch, device: device, progress: progress)
        }
    }

    private func backupScope(target: TransferDestination, local: DirectorySync.LocalRoot,
                             remotePath: [String]) throws -> SyncBackupScope {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SyncBackupScope(device: try encoder.encode(target), local: local, remotePath: remotePath)
    }

    func reloadSyncBackups() async {
        do {
            let records = try await SyncBackupStore.shared.load()
            let sizes = try await SyncBackupStore.shared.storedFileBytes(for: records)
            let deviceCopies = try await SyncBackupStore.shared.deviceCopies(
                including: transferHistory.flatMap(\.deviceRecoveryCopies)
            )
            syncBackups = records
            syncBackupFileBytes = sizes
            deviceRecoveryCopies = deviceCopies
            syncBackupError = nil
        } catch {
            syncBackupError = "无法读取旧版本。\(error.localizedDescription)"
        }
    }

    var pendingSyncBackupIDs: Set<UUID> {
        var ids = Set(syncBackups.filter { !$0.completed }.map(\.id))
        for backup in syncBackups where !backup.completed {
            if let source = backup.update.restoringBackup { ids.insert(source) }
        }
        for batch in transferHistory {
            ids.formUnion(batch.requiredBackupIDs)
        }
        return ids
    }

    func backupCleanupReason(_ backup: SyncBackup) -> String? {
        if isBusy { return "当前操作完成后可清理" }
        if !backup.completed { return "更新未完成，可在传输记录重试" }
        if pendingSyncBackupIDs.contains(backup.id) { return "未完成任务仍需要此备份" }
        return nil
    }

    func exportSyncBackup(_ backup: SyncBackup) {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "导出旧版本"
        let name = URL(fileURLWithPath: backup.update.path.last ?? "文件")
        let suffix = name.pathExtension.isEmpty ? "" : ".\(name.pathExtension)"
        panel.nameFieldStringValue = "\(name.deletingPathExtension().lastPathComponent)-旧版本\(suffix)"
        panel.directoryURL = localFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        syncBackupError = nil
        errorText = nil
        perform("正在导出旧版本") { _ in
            try await SyncBackupStore.shared.exportPrevious(backup.id, to: destination)
            self.status = "已导出旧版本「\(destination.lastPathComponent)」"
        }
    }

    func trashSyncBackup(_ backup: SyncBackup) {
        guard backupCleanupReason(backup) == nil else { return }
        let protectedIDs = pendingSyncBackupIDs
        syncBackupError = nil
        errorText = nil
        perform("正在清理 Mac 备份") { _ in
            try await SyncBackupStore.shared.trashCompleted(backup.id, protectedIDs: protectedIDs)
            await self.reloadSyncBackups()
            self.status = "Mac 备份已移到废纸篓"
        }
    }

    func deviceCopyCleanupReason(_ copy: SyncBackup) -> String? {
        if let reason = backupCleanupReason(copy) { return reason }
        guard let target = try? JSONDecoder().decode(TransferDestination.self, from: copy.scope.device),
              target == transferDestination(root: target.root) else {
            return "请连接记录对应的原设备和存储"
        }
        if deviceInfo?.supportsRecoveryCleanup != true {
            return activeKind == .companion ? "无线清理需要伴侣 0.3.3 或更新版本" : "当前设备不支持恢复副本清理"
        }
        return nil
    }

    func cleanupDeviceRecoveryCopy(_ copy: SyncBackup) {
        guard deviceCopyCleanupReason(copy) == nil, let device,
              let target = try? JSONDecoder().decode(TransferDestination.self, from: copy.scope.device) else { return }
        let protected = pendingSyncBackupIDs
        syncBackupError = nil
        errorText = nil
        perform("正在校验并清理设备恢复副本") { _ in
            let removed = try await SyncBackupStore.shared.cleanupDeviceCopy(
                copy.id, scope: copy.scope, protectedIDs: protected, device: device, volumeRoot: target.root
            )
            await self.reloadSyncBackups()
            self.status = removed ? "设备恢复副本已清理" : "设备副本已不存在，记录已更新"
        }
    }

    func canRestoreBackup(_ backup: SyncBackup) -> Bool {
        guard !isBusy, backup.completed,
              let target = try? JSONDecoder().decode(TransferDestination.self, from: backup.scope.device) else { return false }
        return target == transferDestination(root: target.root)
    }

    func restoreBackup(_ backup: SyncBackup) {
        guard canRestoreBackup(backup), let device,
              let target = try? JSONDecoder().decode(TransferDestination.self, from: backup.scope.device) else { return }
        perform("正在准备恢复旧版本") { progress in
            try backup.scope.local.validate()
            let executor = TransferExecutor(device: device, volumeRoot: target.root,
                                            devicePath: backup.scope.remotePath, localRoot: backup.scope.local.url,
                                            syncRoot: backup.scope.local, backupScope: backup.scope)
            let current = try await executor.updateTargetFingerprint(backup.update)
            if current == backup.update.destination {
                self.status = "文件已与此旧版本一致"
                return
            }
            let update = SyncUpdate(path: backup.update.path, direction: backup.update.direction,
                                    source: backup.update.destination, destination: current, restoringBackup: backup.id)
            let step = TransferStep(name: update.path.joined(separator: "/"), action: .syncUpdate(update))
            let batch = await self.addBatch(title: "恢复旧版本", target: target, path: backup.scope.remotePath,
                                            local: backup.scope.local.url, syncRoot: backup.scope.local,
                                            backupScope: backup.scope, steps: [step])
            await self.runBatch(batch, device: device, progress: progress)
        }
    }

    func chooseAPK() {
        guard let device, let root = remotePath.first?.folder, canSendAPK else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 APK 安装包"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = localFolder
        if let type = UTType(filenameExtension: "apk") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let apk = panel.url else { return }
        guard let target = transferDestination(root: root) else { return }
        perform("正在发送 APK") { progress in
            let step = TransferStep(name: apk.lastPathComponent, action: .apk(apk))
            let batch = await self.addBatch(title: device.kind == .companion ? "发起 APK 安装" : "发送 APK 到 Download",
                                      target: target, path: [], steps: [step])
            await self.runBatch(batch, device: device, progress: progress)
            if self.transferHistory.first(where: { $0.id == batch })?.rows.first?.result == .succeeded {
                self.status = device.kind == .companion
                    ? "已发起安装请求。请到电纸书确认。"
                    : "APK 已传到 Download。请在电纸书上打开安装。"
            }
        }
    }

    func canRetry(_ batch: TransferRecord) -> Bool {
        !isBusy && !batch.retryable.isEmpty && batch.target == transferDestination(root: batch.target.root)
    }

    func retryHelp(_ batch: TransferRecord) -> String {
        if let recordedLaunch = batch.target.launchID, recordedLaunch != launchID {
            return batch.target.connection == .wifi
                ? "原厂 Wi-Fi 传书只能在同一次工具箱运行期间重试"
                : "此记录缺少可跨启动验证的设备或授权目录信息"
        }
        return canRetry(batch) ? "继续传输失败、中断或等待的项目" : "原设备和原目录可用后可重试"
    }

    func retry(_ id: UUID, rowID: UUID? = nil) {
        guard let batch = transferHistory.first(where: { $0.id == id }),
              canRetry(batch), let device else { return }
        perform("正在重试未完成的项目") { progress in
            try batch.syncRoot?.validate()
            await self.runBatch(id, device: device, progress: progress, only: rowID.map { [$0] })
        }
    }

    private func transferDestination(root: DeviceFolder) -> TransferDestination? {
        guard let kind = activeKind, let info = deviceInfo,
              let volume = info.volumes.first(where: { $0.root == root }) else { return nil }
        let identity: String?
        switch kind {
        case .usb:
            identity = info.fields.first { ["USB 序列号", "MTP 序列号"].contains($0.name) && !$0.value.isEmpty }?.value
        case .wifi:
            identity = info.fields.first { $0.name == "局域网地址" }?.value
        case .companion:
            identity = connectionTarget?.id
        }
        let canIdentifyAfterRestart = identity != nil && (kind == .usb || (kind == .companion && volume.identity != nil))
        return .init(connection: kind, identity: identity ?? sessionIdentity, root: root, volumeName: volume.name,
                     volumeIdentity: volume.identity, launchID: canIdentifyAfterRestart ? nil : launchID)
    }

    private func addBatch(
        title: String, target: TransferDestination, path: [String], local: URL? = nil,
        syncRoot: DirectorySync.LocalRoot? = nil, backupScope: SyncBackupScope? = nil,
        steps: [TransferStep], skipped: [TransferRecord.Row] = [], paused: Bool = false
    ) async -> UUID {
        var batch = TransferRecord(title: title, target: target, remotePath: path, localFolder: local, syncRoot: syncRoot,
                                   backupScope: backupScope,
                                   rows: steps.map { TransferRecord.Row(step: $0) } + skipped)
        batch.paused = paused
        transferHistory.append(batch)
        showingTransfers = true
        await saveTransferRecord(batch)
        return batch.id
    }

    private func recordResult(_ result: TransferResult, rowID: UUID, batchID: UUID) async {
        guard let batch = transferHistory.firstIndex(where: { $0.id == batchID }),
              let row = transferHistory[batch].rows.firstIndex(where: { $0.id == rowID }) else { return }
        transferHistory[batch].rows[row].result = result
        if result == .running { transferHistory[batch].rows[row].resumedFrom = nil }
        await saveTransferRecord(transferHistory[batch])
    }

    private func saveTransferRecord(_ record: TransferRecord) async {
        do {
            try await historyStore.save(record)
        } catch {
            transferHistoryWarning = "无法保存部分传输记录，重新打开后可能缺少最新状态。\(error.localizedDescription)"
        }
    }

    private func runBatch(_ id: UUID, device: any DeviceConnection, progress: @escaping ProgressUpdate,
                          only: Set<UUID>? = nil) async {
        guard let batch = transferHistory.first(where: { $0.id == id }) else { return }
        activity = batch.title
        let executor = TransferExecutor(device: device, volumeRoot: batch.target.root,
                                        devicePath: batch.remotePath, localRoot: batch.localFolder,
                                        syncRoot: batch.syncRoot, backupScope: batch.backupScope)
        activeBatchID = id
        defer { activeBatchID = nil; activeRowID = nil; rowOperation = nil }
        if let index = transferHistory.firstIndex(where: { $0.id == id }) {
            transferHistory[index].paused = false
            transferHistory[index].autoResume = true
            await saveTransferRecord(transferHistory[index])
        }
        var attempted = Set<UUID>()
        var interruption: (any Error)?
        while !Task.isCancelled {
            guard let current = transferHistory.first(where: { $0.id == id }) else { break }
            if current.paused == true {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            guard let step = current.retryable.first(where: { !attempted.contains($0.id) && (only == nil || only!.contains($0.id)) }) else { break }
            activeRowID = step.id
            self.progress = nil; transferRate = nil; transferRemaining = nil; rateSample = nil
            await recordResult(.running, rowID: step.id, batchID: id)
            let task = Task { try await executor.execute(step, progress: progress) }
            rowOperation = task
            do {
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                cancelledRows.remove(step.id)
                await recordResult(.succeeded, rowID: step.id, batchID: id)
                attempted.insert(step.id)
            } catch {
                if cancelledRows.remove(step.id) != nil {
                    try? await device.discardResumable(step.id)
                    await recordResult(.cancelled, rowID: step.id, batchID: id)
                    attempted.insert(step.id)
                } else if transferHistory.first(where: { $0.id == id })?.paused == true {
                    transferRate = nil; transferRemaining = nil
                    await recordResult(.interrupted(supportsByteResume && step.isResumableFile ? "已暂停；已传部分已保存，继续时续传" : "已暂停；继续时重试当前文件"), rowID: step.id, batchID: id)
                } else if Task.isCancelled || error is CancellationError {
                    await recordResult(.interrupted("已取消，可重试此项"), rowID: step.id, batchID: id)
                    interruption = error; break
                } else if TransferBatch.reconnectError(error) {
                    await recordResult(.interrupted(error.localizedDescription), rowID: step.id, batchID: id)
                    interruption = error; break
                } else {
                    let result: TransferResult
                    if case ToolboxError.conflict(let name) = error, case .syncUpdate = step.action {
                        result = .failed("\(name) 已改变，请核对后重试")
                    } else if case ToolboxError.conflict(let name) = error {
                        result = .skipped("保留已有同名项目：\(name)")
                    } else { result = .failed(error.localizedDescription) }
                    await recordResult(result, rowID: step.id, batchID: id)
                    attempted.insert(step.id)
                }
            }
            activeRowID = nil; rowOperation = nil
        }
        if let index = transferHistory.firstIndex(where: { $0.id == id }) {
            transferHistory[index].autoResume = !Task.isCancelled && interruption.map(TransferBatch.reconnectError) == true
            await saveTransferRecord(transferHistory[index])
        }
        if batch.backupScope != nil { await reloadSyncBackups() }
        if let local = batch.localFolder, localFolder == local, localLoad == nil {
            openLocal(local, preserveSelection: true)
        }
        if let interruption, TransferBatch.reconnectError(interruption) {
            if connectionTarget != nil {
                await handleCompanionInterruption(interruption)
            } else {
                await resetConnection()
                status = "连接已中断。重新连接后可重试未完成项目。"
            }
            return
        }
        if !Task.isCancelled, batch.localFolder == nil || batch.backupScope != nil, let folder = currentRemoteFolder {
            try? await refreshRemote(device, folder)
        }
        if let record = transferHistory.first(where: { $0.id == id }) {
            status = record.summary
        }
    }

    func submitName(_ name: String, for request: NameRequest) {
        guard let device, let folder = currentRemoteFolder, canManage else { return }
        perform(request.label) { _ in
            try await self.mutate(device, refresh: folder) {
                if let item = request.item {
                    try await device.rename(item, in: folder, to: name)
                } else {
                    _ = try await device.makeFolder(named: name, in: folder)
                }
            }
            self.status = request.item == nil ? "文件夹已创建" : "已重命名"
        }
    }

    func delete(_ request: DeletionRequest) {
        guard let device, let folder = currentRemoteFolder, let root = remotePath.first?.folder,
              let scope = currentTrashScope, canCopyAndDelete else { return }
        let parents = remotePath.dropFirst().map(\.name)
        perform("正在移入回收站") { _ in
            try await self.mutate(device, refresh: folder) {
                for item in request.items {
                    try Task.checkCancellation()
                    try await DeviceTrashStore.shared.put(item, parents: parents, scope: scope, on: device, root: root)
                }
            }
            await self.reloadTrash()
            self.status = "已将 \(request.items.count) 项移入回收站"
        }
    }

    private var currentTrashScope: Data? {
        guard let root = remotePath.first?.folder, let target = transferDestination(root: root), target.launchID == nil else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(target)
    }

    func reloadTrash() async {
        do {
            localTrash = try await LocalTrashStore.shared.load()
            if let scope = currentTrashScope { deviceTrash = try await DeviceTrashStore.shared.load(scope: scope) }
            else { deviceTrash = [] }
        } catch { errorText = error.localizedDescription }
    }

    func trashLocal(_ items: [LocalItem]) {
        guard !isBusy, !items.isEmpty else { return }
        perform("正在回收 Mac 文件") { _ in
            for item in items { try Task.checkCancellation(); try await LocalTrashStore.shared.put(item.url) }
            self.openLocal(self.localFolder)
            await self.reloadTrash()
            self.status = "Mac 文件已移入工具箱回收站"
        }
    }

    func restoreTrash(_ id: UUID, local: Bool, purge: Bool = false) {
        guard !isBusy else { return }
        let device = self.device, root = remotePath.first?.folder, scope = currentTrashScope
        if !local && (!canCopyAndDelete || device == nil || root == nil || scope == nil) {
            errorText = "请连接原设备和存储（无线管理需伴侣 0.4.0）"; return
        }
        perform(purge ? "正在永久清理" : "正在恢复回收文件") { _ in
            if local {
                if purge { try await LocalTrashStore.shared.purge(id) }
                else { _ = try await LocalTrashStore.shared.restore(id) }
                self.openLocal(self.localFolder)
            } else if let device, let root, let scope {
                if purge { try await DeviceTrashStore.shared.purge(id, scope: scope, on: device, root: root) }
                else { _ = try await DeviceTrashStore.shared.restore(id, scope: scope, on: device, root: root) }
                if let folder = self.currentRemoteFolder { try await self.refreshRemote(device, folder) }
            }
            await self.reloadTrash()
            self.status = purge ? "回收副本已永久清理" : "文件已恢复，同名时保留为恢复副本"
        }
    }

    func prepareRelocation(_ items: [DeviceItem], copying: Bool) {
        guard canManage, !items.isEmpty, !copying || canCopyAndDelete else { return }
        relocation = PendingRelocation(items: items, copying: copying)
        status = "已选择 \(items.count) 项，打开目标目录后点「粘贴到此处」"
    }

    func paste() {
        guard let relocation, let device, let folder = currentRemoteFolder, canPaste else { return }
        if relocation.items.contains(where: { item in remotePath.contains { $0.folder == item.folder } }) {
            errorText = "请选择这些项目之外的目标目录。"
            return
        }
        perform(relocation.copying ? "正在复制" : "正在移动") { _ in
            try await self.mutate(device, refresh: folder) {
                var remaining = relocation.items
                for item in relocation.items {
                    try Task.checkCancellation()
                    try await device.relocate(item, to: folder, copying: relocation.copying)
                    remaining.removeFirst()
                    self.relocation = remaining.isEmpty ? nil : .init(items: remaining, copying: relocation.copying)
                }
            }
            self.status = relocation.copying ? "已复制 \(relocation.items.count) 项" : "已移动 \(relocation.items.count) 项"
        }
    }

    func browseHistory(_ pane: BrowserPane, forward: Bool) {
        if pane == .mac {
            if let next = forward ? localNavigation.future.last : localNavigation.past.last {
                openLocal(next, historyOffset: forward ? 1 : -1)
            }
        } else if let next = forward ? remoteNavigation.future.last : remoteNavigation.past.last {
            navigate(next, historyOffset: forward ? 1 : -1)
        }
    }

    func bookmarks(for pane: BrowserPane) -> [BrowserBookmark] {
        bookmarks.filter { pane == .mac ? $0.local != nil : ($0.scope == currentTrashScope && $0.scope != nil) }
    }

    func addBookmark(_ pane: BrowserPane) {
        let value = BrowserBookmark(id: UUID(), scope: pane == .mac ? nil : currentTrashScope,
                                    local: pane == .mac ? localFolder : nil,
                                    names: pane == .mac ? [] : remotePath.dropFirst().map(\.name))
        guard pane == .mac || value.scope != nil else { return }
        guard !bookmarks.contains(where: { $0.scope == value.scope && $0.local == value.local && $0.names == value.names }) else { return }
        bookmarks.append(value); BrowserBookmark.save(bookmarks)
    }

    func removeBookmark(_ id: UUID) { bookmarks.removeAll { $0.id == id }; BrowserBookmark.save(bookmarks) }

    func openBookmark(_ bookmark: BrowserBookmark) {
        if let local = bookmark.local { openLocal(local) }
        else if bookmark.scope == currentTrashScope { jumpDirectory(bookmark.names.joined(separator: "/"), pane: .device) }
    }

    func jumpDirectory(_ path: String, pane: BrowserPane) {
        if pane == .mac {
            let expanded = (path as NSString).expandingTildeInPath
            openLocal(URL(fileURLWithPath: expanded.hasPrefix("/") ? expanded : localFolder.appendingPathComponent(expanded).path))
            return
        }
        guard let device, let first = remotePath.first else { return }
        var names = path.split(separator: "/").map(String.init)
        if names.first == first.name { names.removeFirst() }
        guard !names.contains(DeviceTrashStore.folderName) else { errorText = "请通过回收站管理此目录"; return }
        let components = names
        perform("正在跳转目录") { _ in
            var breadcrumbs = [first]
            var entries = try await device.list(first.folder)
            for name in components {
                try validateFileName(name)
                let matches = entries.filter { DirectorySync.nameKey($0.name) == DirectorySync.nameKey(name) }
                guard matches.count == 1, let item = matches.first, item.name == name, let folder = item.folder else {
                    throw ToolboxError.message("目录「\(name)」不存在或存在重名")
                }
                breadcrumbs.append(.init(name: name, folder: folder))
                entries = try await device.list(folder)
            }
            self.remoteNavigation.visit(breadcrumbs)
            self.remotePath = breadcrumbs; self.remoteItems = entries; self.remoteSelection = []
            self.rememberCompanionFolder()
        }
    }

    func previewRemote(_ item: DeviceItem) {
        guard let device, !item.isFolder, !isBusy else { return }
        perform("正在准备设备预览") { progress in
            try validateFileName(item.name)
            let cache = FileManager.default.temporaryDirectory.appending(path: "HanvonToolbox-Preview/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = cache.appendingPathComponent(item.name)
            do { try await device.download(item, to: file, progress: progress) }
            catch { try? FileManager.default.removeItem(at: cache); throw error }
            if let old = self.previewCache { try? FileManager.default.removeItem(at: old) }
            self.previewCache = cache
            self.previewURL = file
            self.status = "设备文件已下载到临时预览区"
        }
    }

    func searchFiles() {
        guard !isBusy, !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let onDevice = searchOnDevice, root = localFolder, path = remotePath, device = self.device
        searchHits = []
        searchSession = sessionIdentity
        perform("正在搜索子目录") { _ in
            if onDevice {
                guard let device, let folder = path.last?.folder else { throw ToolboxError.message("请先连接设备") }
                var seen = Set<DeviceFolder>(), hits: [BrowserSearchHit] = [], scanned = 0
                func walk(_ folder: DeviceFolder, parents: [Breadcrumb], relative: [String]) async throws {
                    try Task.checkCancellation()
                    guard parents.count < 64, seen.insert(folder).inserted else { throw ToolboxError.message("目录层级过深或包含循环") }
                    for item in try await device.list(folder) where !item.name.hasPrefix(".") && !SyncBackup.isWorkingFile(item.name) {
                        scanned += 1
                        guard scanned <= 20000, hits.count < 1000 else { throw ToolboxError.message("搜索范围过大，请从更小的目录搜索") }
                        let itemPath = relative + [item.name]
                        if item.name.localizedStandardContains(query) {
                            hits.append(.init(path: itemPath, local: nil, remoteParents: parents, name: item.name))
                        }
                        if let child = item.folder { try await walk(child, parents: parents + [.init(name: item.name, folder: child)], relative: itemPath) }
                    }
                }
                try await walk(folder, parents: path, relative: [])
                self.searchHits = hits
            } else {
                let search = Task.detached { try Self.searchLocalFiles(root, query: query) }
                let found = try await withTaskCancellationHandler { try await search.value } onCancel: { search.cancel() }
                self.searchHits = found.map { .init(path: $0.1, local: $0.0, remoteParents: nil, name: $0.0.lastPathComponent) }
            }
            self.status = "找到 \(self.searchHits.count) 项"
        }
    }

    nonisolated static func searchLocalFiles(_ root: URL, query: String) throws -> [(URL, [String])] {
        let root = root.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else {
            throw ToolboxError.message("无法搜索 Mac 目录")
        }
        var results: [(URL, [String])] = [], scanned = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true || values.isPackage == true { enumerator.skipDescendants(); continue }
            scanned += 1
            guard scanned <= 20000, results.count < 1000 else { throw ToolboxError.message("搜索范围过大，请从更小的目录搜索") }
            if url.lastPathComponent.localizedStandardContains(query) {
                results.append((url, Array(url.pathComponents.suffix(enumerator.level))))
            }
        }
        return results
    }

    func revealSearchHit(_ hit: BrowserSearchHit) {
        guard !isBusy else { return }
        perform("正在定位搜索结果") { _ in
            if let local = hit.local {
                let parent = local.deletingLastPathComponent()
                self.localItems = try await Self.readLocal(parent)
                self.localFolder = parent; self.localNavigation.visit(parent); self.localSelection = [local]
            } else if let parents = hit.remoteParents, let folder = parents.last?.folder, let device = self.device {
                guard self.searchSession == self.sessionIdentity else { throw ToolboxError.message("设备连接已变化，请重新搜索") }
                let entries = try await device.list(folder)
                guard let item = entries.first(where: { $0.name == hit.name }) else { throw ToolboxError.message("结果已移动，请重新搜索") }
                self.remotePath = parents; self.remoteNavigation.visit(parents)
                self.remoteItems = entries; self.remoteSelection = [item.id]; self.rememberCompanionFolder()
            }
            self.showingSearch = false
        }
    }

    func beginSearch(_ pane: BrowserPane) {
        searchOnDevice = pane == .device; searchQuery = ""; searchHits = []; showingSearch = true
    }

    func pauseQueue(_ id: UUID, paused: Bool) {
        guard let index = transferHistory.firstIndex(where: { $0.id == id }) else { return }
        transferHistory[index].paused = paused
        if paused && activeBatchID == id { rowOperation?.cancel() }
        Task { await saveTransferRecord(transferHistory[index]) }
        if !paused && activeBatchID != id { retry(id) }
    }

    func cancelRow(_ batchID: UUID, _ rowID: UUID) {
        guard let index = transferHistory.firstIndex(where: { $0.id == batchID }),
              let row = transferHistory[index].rows.firstIndex(where: { $0.id == rowID }) else { return }
        if activeRowID == rowID { cancelledRows.insert(rowID); rowOperation?.cancel() }
        else if transferHistory[index].rows[row].result.canRetry {
            transferHistory[index].rows[row].result = .cancelled
            let batch = transferHistory[index]
            if batch.target.connection == .companion, let volume = batch.target.volumeIdentity {
                FileTransfers.clearResumableCache(deviceIdentity: batch.target.identity, volumeIdentity: volume, transferID: rowID)
            }
            let connected = batch.target == transferDestination(root: batch.target.root) ? device : nil
            Task { await saveTransferRecord(batch); try? await connected?.discardResumable(rowID) }
        }
    }

    func moveQueuedRow(_ batchID: UUID, _ rowID: UUID, by offset: Int) {
        guard let index = transferHistory.firstIndex(where: { $0.id == batchID }) else { return }
        transferHistory[index].movePending(rowID, by: offset, active: activeRowID)
        Task { await saveTransferRecord(transferHistory[index]) }
    }

    private func resumeQueuedTransfers() {
        guard !isBusy, let batch = transferHistory.first(where: { $0.autoResume == true && $0.paused != true && canRetry($0) }) else { return }
        retry(batch.id)
    }

    func cancel() {
        rowOperation?.cancel()
        if let id = activeBatchID, let index = transferHistory.firstIndex(where: { $0.id == id }) {
            transferHistory[index].paused = false; transferHistory[index].autoResume = false
        }
        operation?.cancel()
    }

    private func mutate(
        _ device: any DeviceConnection, refresh folder: DeviceFolder?, operation: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            if let folder, !Task.isCancelled, (error as? ToolboxError)?.needsReconnect != true {
                try? await refreshRemote(device, folder)
            }
            throw error
        }
        if let folder { try await refreshRemote(device, folder) }
    }

    private func refreshRemote(_ device: any DeviceConnection, _ folder: DeviceFolder) async throws {
        remoteItems = try await device.list(folder)
        remoteSelection.formIntersection(browsableRemoteItems.map(\.id))
    }

    private func resetConnection() async {
        healthTask?.cancel()
        healthTask = nil
        await device?.close()
        connectionTarget = nil
        device = nil
        activeKind = nil
        deviceInfo = nil
        remoteItems = []
        remoteSelection = []
        remotePath = []
        relocation = nil
    }

    private func perform(_ label: String, work: @escaping @MainActor (@escaping ProgressUpdate) async throws -> Void) {
        guard !isBusy else { return }
        let id = UUID()
        activityID = id
        activity = label
        progress = nil
        let lastUpdate = OSAllocatedUnfairLock(initialState: TimeInterval.zero)
        let update: ProgressUpdate = { [weak self] progress in
            let now = ProcessInfo.processInfo.systemUptime
            let shouldUpdate = lastUpdate.withLock { last in
                guard now - last >= 0.1 || progress.completed == progress.total || progress.resumedFrom != nil else { return false }
                last = now
                return true
            }
            guard shouldUpdate else { return }
            Task { @MainActor [weak self] in
                if let self, self.activityID == id {
                    self.progress = progress
                    if let offset = progress.resumedFrom, let batchID = self.activeBatchID, let rowID = self.activeRowID,
                       let batch = self.transferHistory.firstIndex(where: { $0.id == batchID }),
                       let row = self.transferHistory[batch].rows.firstIndex(where: { $0.id == rowID }) {
                        self.transferHistory[batch].rows[row].resumedFrom = offset
                    }
                    if let sample = self.rateSample, progress.completed >= sample.bytes, now - sample.time >= 0.25 {
                        let rate = Double(progress.completed - sample.bytes) / (now - sample.time)
                        self.transferRate = self.transferRate.map { $0 * 0.6 + rate * 0.4 } ?? rate
                        if let total = progress.total, let speed = self.transferRate, speed > 0 {
                            self.transferRemaining = Double(total - min(total, progress.completed)) / speed
                        }
                        self.rateSample = (now, progress.completed)
                    } else if self.rateSample == nil || progress.completed < self.rateSample!.bytes {
                        self.rateSample = (now, progress.completed)
                    }
                }
            }
        }
        operation = Task {
            defer {
                activityID = nil
                activity = nil
                progress = nil
                operation = nil
                alignCompanion()
                resumeQueuedTransfers()
            }
            do {
                try await work(update)
            } catch {
                if !Task.isCancelled, connectionTarget != nil, TransferBatch.reconnectError(error) {
                    await handleCompanionInterruption(error)
                    return
                }
                if (error as? ToolboxError)?.needsReconnect == true {
                    await resetConnection()
                }
                if Task.isCancelled {
                    status = activeKind == nil ? "操作已取消，请重新连接设备" : "操作已取消"
                    return
                }
                status = "操作未完成"
                errorText = error.localizedDescription
            }
        }
    }
}
