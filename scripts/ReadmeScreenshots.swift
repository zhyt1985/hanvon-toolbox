import AppKit
import SwiftUI
import ToolboxCore

@MainActor
struct ReadmeScreenshots {
    static let date = Date(timeIntervalSince1970: 1767225600)
    static func makeModel() -> ToolboxModel {
        let m = ToolboxModel()
        m.mode = .companion; m.activeKind = .companion
        m.localFolder = URL(fileURLWithPath: "/示例资料/电子书")
        m.localItems = [
            .init(url: m.localFolder.appending(path: "笔记导出"), isFolder: true, size: nil, modified: date),
            .init(url: m.localFolder.appending(path: "阅读资料"), isFolder: true, size: nil, modified: date),
            .init(url: m.localFolder.appending(path: "阅读示例.pdf"), isFolder: false, size: 2_621_440, modified: date),
            .init(url: m.localFolder.appending(path: "使用说明.txt"), isFolder: false, size: 4096, modified: date)]
        let root = DeviceFolder.companion(path: "")
        m.remotePath = [.init(name: "共享目录（演示）", folder: root), .init(name: "书库", folder: .companion(path: "书库"))]
        m.remoteItems = [
            .init(id: .companion(path: "书库/阅读资料"), name: "阅读资料", folder: .companion(path: "书库/阅读资料"), modified: date),
            .init(id: .companion(path: "书库/阅读示例.pdf"), name: "阅读示例.pdf", size: 2_621_440, modified: date),
            .init(id: .companion(path: "书库/摘录示例.txt"), name: "摘录示例.txt", size: 8192, modified: date)]
        m.remoteSelection = [.companion(path: "书库/阅读示例.pdf")]
        m.deviceInfo = .init(name: "N10 Plus（演示）", fields: [], volumes: [.init(name: "共享目录（演示）", root: root, identity: "synthetic-volume")], supportsAPK: true, canManageFiles: true, supportsRecoveryCleanup: true, supportsFileOperations: true, supportsResumableTransfers: true, supportsContentSources: true, supportsContentSnapshots: true)
        m.nearby = [.init(id: "synthetic-device", name: "N10 Plus（演示）", address: "https://192.0.2.2")]
        m.companionSelection = "synthetic-device"
        m.discoveryNote = "演示设备";m.status = "无线管理 · 演示数据（未连接真实设备）"
        return m
    }
    static func banner<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack { Label("界面演示 · 全部为合成数据", systemImage: "info.circle");Spacer();Text("未访问真实设备或个人文件") }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 9).background(.quaternary.opacity(0.3))
            Divider();content()
        }.environment(\.locale, Locale(identifier: "zh_CN")).preferredColorScheme(.light)
    }
    static func save<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "汉王电纸书工具箱 · 演示"
        let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Color.white))
        host.sizingOptions = [];host.frame = .init(x: 0, y: 0, width: width, height: height);window.contentView = host
        window.center();window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "docs/assets/screenshots/" + name + ".png")
        try data.write(to: file);window.orderOut(nil);print(name + ": " + String(bitmap.pixelsWide) + "x" + String(bitmap.pixelsHigh))
    }
    static func render() throws {
        try save(banner { ToolboxView() }, name: "file-manager", width: 1380, height: 780)
        let m = makeModel()
        let target = TransferDestination(connection: .companion, identity: "synthetic-device", root: .companion(path: ""), volumeName: "共享目录（演示）", volumeIdentity: "synthetic-volume", launchID: nil)
        var record = TransferRecord(title: "上传到电纸书", target: target, remotePath: ["书库"], localFolder: m.localFolder, rows: [
            .init(step: .init(name: "阅读示例.pdf", action: .upload(m.localFolder.appending(path: "阅读示例.pdf"), directories: [])), result: .succeeded),
            .init(step: .init(name: "合成大文件.bin", action: .upload(m.localFolder.appending(path: "合成大文件.bin"), directories: [])), result: .interrupted("已暂停，连接原设备后可继续")),
            .init(step: .init(name: "使用说明.txt", action: .upload(m.localFolder.appending(path: "使用说明.txt"), directories: [])), result: .waiting)])
        record.paused = true;record.rows[1].resumedFrom = 16 * 1024 * 1024;m.transferHistory = [record]
        try save(banner { TransferHistoryView(model: m) }, name: "transfer-queue", width: 940, height: 580)
        let content = ContentExportModel()
        let origin = ContentSource(connection: .companion, deviceScope: "synthetic-source", path: [], kind: .notes, displayName: "合成笔记库")
        content.catalog = .init(source: origin, items: [
            .init(id: "synthetic-note-001", title: "合成笔记 · 阅读摘录", path: ["synthetic-note-001"], isDirectory: true, modified: date, indexed: true),
            .init(id: "synthetic-note-002", title: "合成笔记 · 会议提纲", path: ["synthetic-note-002"], isDirectory: true, modified: date, indexed: true),
            .init(id: "synthetic-note-003", title: "合成笔记 · 学习计划", path: ["synthetic-note-003"], isDirectory: true, modified: date, indexed: true)], warnings: ["原始目录副本不等于 PDF，不承诺可回写恢复；笔记与便签暂未分类。"])
        content.selection = ["synthetic-note-001", "synthetic-note-002"]
        try save(banner { ContentExportView(toolbox: m, model: content) }, name: "content-export", width: 1120, height: 740)
    }
}
@main struct Render {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        try ReadmeScreenshots.render()
    }
}
