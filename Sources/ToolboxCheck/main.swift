import Foundation
import ToolboxCore

enum CheckError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError.failed(message) }
}

func checkUSB(in temp: URL, fixture: URL?) async throws {
    let device: any DeviceConnection = try await USBDevice.connect()
    do {
        let info = try await device.info()
        guard let root = info.volumes.first?.root else { throw CheckError.failed("USB 没有公开存储。") }
        let roots = try await device.list(root)
        guard let download = roots.first(where: { $0.name == "Download" })?.folder else {
            throw CheckError.failed("USB 存储没有 Download 目录。")
        }
        try require(info.canManageFiles && info.supportsAPK, "USB 设备缺少预期的管理能力。")
        print("USB：设备信息与根目录通过（\(info.name)，\(roots.count) 项）")
        try await checkUSBFolders(device: device, download: download, temp: temp)
        if let fixture {
            try await checkAPK(device: device, root: root, download: download, temp: temp, fixture: fixture)
        }
        await device.close()
    } catch {
        await device.close()
        throw error
    }
}

func checkUSBFolders(device: any DeviceConnection, download: DeviceFolder, temp: URL) async throws {
    let tempName = "HanvonToolbox-check-\(UUID().uuidString)"
    let test = try await device.makeFolder(named: tempName, in: download)
    do {
        guard let folder = test.folder else { throw CheckError.failed("新目录缺少访问句柄。") }
        let target = try await device.makeFolder(named: "目标目录", in: folder)
        guard let targetFolder = target.folder else { throw CheckError.failed("目标目录缺少访问句柄。") }
        let local = temp.appendingPathComponent("USB-check.bin")
        // The 12-byte MTP header brings this payload to a USB packet boundary.
        let bytes = Data(repeating: 0xA5, count: 2 * 1024 * 1024 - 12)
        try bytes.write(to: local)
        try await FileTransfers.upload(local, to: folder, on: device, progress: nil)
        let entries = try await device.list(folder)
        guard let uploaded = entries.first(where: { $0.name == local.lastPathComponent }) else {
            throw CheckError.failed("USB 上传后没有列出文件。")
        }
        do {
            try await FileTransfers.upload(local, to: folder, on: device, progress: nil)
            throw CheckError.failed("USB 同名文件被覆盖。")
        } catch ToolboxError.conflict(_) {
            print("USB：同名冲突保护通过")
        }

        try await device.rename(uploaded, in: folder, to: "重命名测试.bin")
        let renamedItems = try await device.list(folder)
        guard let renamed = renamedItems.first(where: { $0.name == "重命名测试.bin" }) else {
            throw CheckError.failed("USB 重命名失败。")
        }
        try await device.relocate(renamed, to: targetFolder, copying: true)
        let copies = try await device.list(targetFolder)
        guard let copy = copies.first(where: { $0.name == renamed.name }) else {
            throw CheckError.failed("USB 复制失败。")
        }
        try await device.rename(copy, in: targetFolder, to: "副本.bin")
        try await device.relocate(renamed, to: targetFolder, copying: false)
        let names = try await device.list(targetFolder)
        try require(Set(names.map(\.name)) == ["重命名测试.bin", "副本.bin"], "USB 复制或移动结果异常。")
        let directory = temp.appendingPathComponent("readback")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for entry in names {
            try await FileTransfers.download(entry, to: directory, on: device, progress: nil)
            let returned = try Data(contentsOf: directory.appendingPathComponent(entry.name))
            try require(returned == bytes, "USB 下载内容与原文件不同。")
            try await device.delete(entry)
        }
        let remaining = try await device.list(targetFolder)
        try require(remaining.isEmpty, "USB 删除后的目录非空。")
        try await device.rename(target, in: folder, to: "已改名目录")
        let renamedFolders = try await device.list(folder)
        try require(renamedFolders.map(\.name) == ["已改名目录"], "USB 目录重命名或移动异常。")
        print("USB：创建、中文重命名、复制、移动、删除及约 2 MiB 传输逐字节校验通过")
        try await device.delete(test)
    } catch {
        try? await device.delete(test)
        throw error
    }
    let entries = try await device.list(download)
    try require(!entries.contains(where: { $0.name == tempName }), "USB 测试目录仍存在。")
}

func checkAPK(device: any DeviceConnection, root: DeviceFolder, download: DeviceFolder, temp: URL, fixture: URL) async throws {
    let staged = temp.appendingPathComponent("Hanvon-APK-check-\(UUID().uuidString).apk")
    try FileManager.default.copyItem(at: fixture, to: staged)
    try await FileTransfers.sendAPK(staged, to: root, on: device, progress: nil)
    let entries = try await device.list(download)
    guard let item = entries.first(where: { $0.name == staged.lastPathComponent }) else {
        throw CheckError.failed("未在 Download 找到测试 APK。")
    }
    do {
        let returned = temp.appendingPathComponent("returned.apk")
        try await device.download(item, to: returned, progress: nil)
        let original = try Data(contentsOf: fixture)
        let readback = try Data(contentsOf: returned)
        try require(original == readback, "APK 校验失败。")
        try await device.delete(item)
        print("USB：发送 APK 到 Download，读回校验并清理通过")
    } catch {
        try? await device.delete(item)
        throw error
    }
}

func checkWiFi(address: String, in temp: URL) async throws {
    let device = try await WiFiDevice.connect(address: address)
    do {
        let root = DeviceFolder.wifi(path: nil)
        let entries = try await device.list(root)
        guard let download = entries.first(where: { $0.name == "Download" })?.folder else {
            throw CheckError.failed("无线存储没有展示 Download 目录。")
        }
        let visible = try await device.list(download)
        print("Wi-Fi：根目录及 Download 浏览通过（\(entries.count) / \(visible.count) 项）")

        let name = "Hanvon WiFi 测试 \(UUID().uuidString).txt"
        let test = temp.appendingPathComponent(name)
        let bytes = Data("Hanvon Toolbox Wi-Fi transfer check\n".utf8)
        try bytes.write(to: test)
        try await FileTransfers.upload(test, to: root, on: device, progress: nil)
        do {
            let returned = temp.appendingPathComponent("wifi-readback.txt")
            try await device.downloadUploaded(named: name, to: returned)
            let actual = try Data(contentsOf: returned)
            try require(actual == bytes, "Wi-Fi 下载内容与原文件不同。")
            try await device.deleteUploaded(named: name)
            print("Wi-Fi：中文文件名上传、下载逐字节校验及清理通过")
        } catch {
            try? await device.deleteUploaded(named: name)
            throw error
        }
        await device.close()
    } catch {
        await device.close()
        throw error
    }
}

func checkCompanion(address: String, fingerprint: String, code: String, temp: URL, apk: URL?) async throws {
    let device = try await CompanionDevice.connect(address: address, fingerprint: fingerprint, code: code)
    do {
        let info = try await device.info()
        guard let root = info.volumes.first?.root else { throw CheckError.failed("伴侣应用没有授权目录。") }
        let existing = try await device.list(root)
        print("无线管理：HTTPS 配对、设备信息和目录列表通过（\(info.name)，\(existing.count) 项）")
        if let apk {
            try await device.requestAPKInstall(apk, progress: nil)
            print("无线管理：设备已接收 APK 并登记安装请求")
        } else {
            let name = "Hanvon-Check-" + UUID().uuidString.prefix(8)
            let fixture = try await device.makeFolder(named: name, in: root)
            print("无线管理测试目录：\(name)")
            guard let scratch = fixture.folder else { throw CheckError.failed("测试目录缺少路径。") }
            let source = try await device.makeFolder(named: "上传目录", in: scratch)
            let target = try await device.makeFolder(named: "移动目标", in: scratch)
            guard let sourceFolder = source.folder, let targetFolder = target.folder else {
                throw CheckError.failed("子目录创建失败。")
            }
            let local = temp.appendingPathComponent("联调+文件 #1.txt")
            let original = Data(repeating: 0x41, count: 2 * 1024 * 1024 + 3)
            try original.write(to: local)
            try await FileTransfers.upload(local, to: sourceFolder, on: device, progress: nil)
            let rows = try await device.list(sourceFolder)
            guard let item = rows.first(where: { $0.name == local.lastPathComponent }) else {
                throw CheckError.failed("指定目录没有列出上传文件。")
            }
            try await device.rename(item, in: sourceFolder, to: "已重命名.txt")
            let renamed = try await device.list(sourceFolder)
            guard let file = renamed.first(where: { $0.name == "已重命名.txt" }) else {
                throw CheckError.failed("重命名后未找到文件。")
            }
            try await device.relocate(file, to: targetFolder, copying: false)
            let oldFolder = try await device.list(sourceFolder)
            try require(oldFolder.isEmpty, "移动后原目录仍包含文件。")
            let destination = try await device.list(targetFolder)
            guard let moved = destination.first(where: { $0.name == file.name }) else {
                throw CheckError.failed("移动目标未找到文件。")
            }
            try await FileTransfers.download(moved, to: temp, on: device, progress: nil)
            let received = try Data(contentsOf: temp.appendingPathComponent(file.name))
            try require(original == received, "下载内容不一致。")
            print("无线管理：指定目录上传、新建、重命名、移动、下载逐字节校验通过")
        }
        await device.close()
    } catch {
        await device.close()
        throw error
    }
}

@MainActor
func checkDiscovery() async throws {
    let browser = CompanionDiscovery()
    var resolved = [DiscoveredCompanion]()
    browser.onChange = { resolved = $0 }
    browser.start()
    defer { browser.stop() }
    for _ in 0..<40 {
        if !resolved.isEmpty {
            for device in resolved {
                print("发现设备：\(device.name) \(device.address) 指纹 \(device.id.prefix(16))")
            }
            return
        }
        try await Task.sleep(for: .milliseconds(300))
    }
    throw CheckError.failed("等待 12 秒后仍未发现伴侣服务。")
}

let args = Array(CommandLine.arguments.dropFirst())
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hanvon-check-\(UUID().uuidString)")
do {
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    switch args.first {
    case "--usb" where args.count <= 2:
        try await checkUSB(in: temp, fixture: args.dropFirst().first.map { URL(fileURLWithPath: $0) })
    case "--wifi" where args.count == 2:
        try await checkWiFi(address: args[1], in: temp)
    case "--unplug-usb" where args.count == 1:
        try await unplugUSB(in: temp)
    case "--stress-usb" where args.count == 1:
        try await stressUSB(in: temp)
    case "--stress-companion" where args.count == 1:
        guard let code = readLine() else { throw CheckError.failed("请通过 stdin 提供一次性配对码。") }
        try await stressCompanion(code: code, in: temp)
    case "--discover" where args.count == 1:
        try await checkDiscovery()
    case "--companion" where (3...4).contains(args.count):
        guard let code = readLine() else { throw CheckError.failed("请通过 stdin 提供一次性配对码。") }
        try await checkCompanion(address: args[1], fingerprint: args[2], code: code, temp: temp,
                                 apk: args.dropFirst(3).first.map { URL(fileURLWithPath: $0) })
    default:
        throw CheckError.failed("用法：toolbox-check --usb [APK] | --wifi 地址 | --discover | --companion 地址 指纹 [APK] | --stress-usb | --stress-companion")
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
