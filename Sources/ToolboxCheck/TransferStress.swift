import CryptoKit
import Foundation
import IOKit
import os
import ToolboxCore

private actor Results {
    var values: [UUID: TransferResult] = [:]

    func record(_ id: UUID, _ result: TransferResult) { values[id] = result }

    func result(for id: UUID) -> TransferResult? { values[id] }
}

@MainActor
func findStressCompanion() async throws -> DiscoveredCompanion {
    let browser = CompanionDiscovery()
    var matches: [DiscoveredCompanion] = []
    browser.onChange = { matches = $0 }
    browser.start()
    defer { browser.stop() }
    for _ in 0..<40 {
        if matches.count > 1 { throw CheckError.failed("请仅保留一台电纸书运行伴侣服务。") }
        if let match = matches.first { return match }
        try await Task.sleep(for: .milliseconds(300))
    }
    throw CheckError.failed("未发现电纸书。")
}

func stressUSB(in temp: URL) async throws {
    let device: any DeviceConnection = try await USBDevice.connect()
    do {
        let info = try await device.info()
        guard let root = info.volumes.first?.root else { throw CheckError.failed("USB 未公开存储。") }
        let roots = try await device.list(root)
        guard let download = roots.first(where: { $0.name == "Download" })?.folder else {
            throw CheckError.failed("USB 存储中没有 Download。")
        }
        let scratch = try await device.makeFolder(named: stressName(), in: download)
        guard let folder = scratch.folder else { throw CheckError.failed("未创建 USB 测试目录。") }
        do {
            try await validateBatch(
                TransferExecutor(device: device, volumeRoot: root, devicePath: ["Download", scratch.name], localRoot: temp),
                folder: folder, in: temp
            )
            try await device.delete(scratch)
        } catch {
            try? await device.delete(scratch)
            throw error
        }
        let remaining = try await device.list(download)
        try require(!remaining.contains(where: { $0.name == scratch.name }), "USB 临时目录仍存在。")
        await device.close()
    } catch {
        await device.close()
        throw error
    }
}

func stressCompanion(code: String, in temp: URL) async throws {
    let found = try await findStressCompanion()
    let (device, credentials) = try await CompanionDevice.pair(
        address: found.address, fingerprint: String(found.id.prefix(16)), code: code, discoveredID: found.id
    )
    do {
        let info = try await device.info()
        guard let root = info.volumes.first?.root else { throw CheckError.failed("伴侣应用未公开目录。") }
        let scratch = try await device.makeFolder(named: stressName(), in: root)
        guard let folder = scratch.folder else { throw CheckError.failed("未创建无线测试目录。") }
        print("无线真机测试目录：\(scratch.name)")
        let executor = TransferExecutor(device: device, volumeRoot: root, devicePath: [scratch.name], localRoot: temp)
        try await validateBatch(executor, folder: folder, in: temp)

        let dropped = temp.appendingPathComponent("模拟中断.dat")
        try FileManager.default.copyItem(at: temp.appendingPathComponent("120MiB.dat"), to: dropped)
        let later = temp.appendingPathComponent("还未开始.txt")
        try Data("pending\n".utf8).write(to: later)
        let steps = try await TransferBatch.planUpload([dropped, later], kind: .companion)
        let result = Results()
        let (progress, sink) = AsyncStream.makeStream(of: TransferProgress.self, bufferingPolicy: .bufferingNewest(1))
        let upload = Task {
            await TransferBatch.run(steps, executor: executor, progress: { event in sink.yield(event) }) { id, status in
                await result.record(id, status)
            }
            sink.finish()
        }
        for await bytes in progress where bytes.completed >= 4 * 1024 * 1024 {
            upload.cancel()
            break
        }
        await upload.value
        guard case .interrupted? = await result.result(for: steps[0].id) else {
            throw CheckError.failed("未能在上传进行中模拟中断。")
        }
        let waiting = await result.result(for: steps[1].id)
        try require(waiting == nil, "链接中断后队列仍启动了下一项。")

        await device.close()
        let reconnected = try await CompanionDevice.reconnect(address: found.address, credentials: credentials)
        do {
            let entries = try await reconnected.list(folder)
            try require(!entries.contains(where: { $0.name == dropped.lastPathComponent }), "设备公开了未传完的文件。")
            let retry = TransferExecutor(device: reconnected, volumeRoot: root,
                                         devicePath: [scratch.name], localRoot: temp)
            let failure = await TransferBatch.run(steps, executor: retry, progress: nil) { id, status in
                await result.record(id, status)
            }
            try require(failure == nil, "重连后的重试被中断。")
            guard case .succeeded? = await result.result(for: steps[0].id),
                  case .succeeded? = await result.result(for: steps[1].id) else {
                throw CheckError.failed("重试没有传完中断项及等待项。")
            }
            let readback = temp.appendingPathComponent("simulated-retry")
            try FileManager.default.createDirectory(at: readback, withIntermediateDirectories: false)
            let updated = try await reconnected.list(folder)
            guard let complete = updated.first(where: { $0.name == dropped.lastPathComponent }) else {
                throw CheckError.failed("未找到重传文件。")
            }
            try await reconnected.download(complete, to: readback.appendingPathComponent(complete.name), progress: nil)
            let retriesMatch = try hash(dropped) == hash(readback.appendingPathComponent(complete.name))
            try require(retriesMatch, "重传文件 SHA-256 不一致。")
            print("无线管理：在上传中取消、无半成品正式文件、重连后重试及 SHA-256 校验通过")
            await reconnected.close()
        } catch {
            await reconnected.close()
            throw error
        }
    } catch {
        await device.close()
        throw error
    }
}

private func validateBatch(_ executor: TransferExecutor, folder: DeviceFolder, in temp: URL) async throws {
    let large = temp.appendingPathComponent("120MiB.dat")
    try fill(large)
    let duplicate = temp.appendingPathComponent("保留同名.txt")
    let original = Data("keep existing file\n".utf8)
    try original.write(to: duplicate)
    try await executor.device.upload(duplicate, to: folder, progress: nil)
    try Data("must not replace\n".utf8).write(to: duplicate)
    let missing = temp.appendingPathComponent("稍后重试.txt")
    let small = try (1...16).map { index in
        let file = temp.appendingPathComponent("文件-\(index).txt")
        try Data("fixture \(index)\n".utf8).write(to: file)
        return file
    }
    var steps = try await TransferBatch.planUpload([duplicate, large] + small, kind: executor.device.kind)
    let retryStep = TransferStep(name: missing.lastPathComponent, action: .upload(missing, directories: []))
    steps.insert(retryStep, at: 1)
    let result = Results()
    let interruption = await TransferBatch.run(steps, executor: executor, progress: nil) { id, status in
        await result.record(id, status)
    }
    try require(interruption == nil, "单文件错误中断了整个批次。")
    guard case .skipped? = await result.result(for: steps[0].id),
          case .failed? = await result.result(for: retryStep.id) else {
        throw CheckError.failed("未得到预期的跳过、失败状态。")
    }
    for step in steps.dropFirst(2) {
        try require(await result.result(for: step.id) == .succeeded, "批量中有文件未成功。")
    }

    try Data("retry successful\n".utf8).write(to: missing)
    let retry = await TransferBatch.run([retryStep], executor: executor, progress: nil) { id, status in
        await result.record(id, status)
    }
    let retryResult = await result.result(for: retryStep.id)
    try require(retry == nil && retryResult == .succeeded, "单项重试失败。")

    let output = temp.appendingPathComponent("stress-readback")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let entries = try await executor.device.list(folder)
    let downloader = TransferExecutor(device: executor.device, volumeRoot: executor.volumeRoot,
                                      devicePath: executor.devicePath, localRoot: output)
    let downloads = try await TransferBatch.planDownload(entries, device: executor.device)
    let downloadResults = Results()
    let downloadError = await TransferBatch.run(downloads, executor: downloader, progress: nil) { id, status in
        await downloadResults.record(id, status)
    }
    try require(downloadError == nil && downloads.count == steps.count, "批量下载中断或数量错误。")
    for download in downloads {
        try require(await downloadResults.result(for: download.id) == .succeeded, "批量下载有失败项目。")
    }
    let originalDigest = try hash(large)
    try require(try hash(output.appendingPathComponent(large.lastPathComponent)) == originalDigest, "大文件 SHA-256 不一致。")
    try require(try Data(contentsOf: output.appendingPathComponent(duplicate.lastPathComponent)) == original, "同名文件被覆盖。")
    for source in small + [missing] {
        let uploaded = try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent))
        try require(try Data(contentsOf: source) == uploaded, "小文件内容不一致。")
    }
    print("\(executor.device.kind.rawValue)：120 MiB 和 16 个小文件双向校验、同名跳过、单项失败及重试通过")
}

private func stressName() -> String {
    "Hanvon-Stress-" + UUID().uuidString.prefix(8)
}

private func fill(_ destination: URL) throws {
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
        throw CheckError.failed("无法创建 120 MiB 本地样本。")
    }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    let pattern = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8)) })
    for _ in 0..<120 { try output.write(contentsOf: pattern) }
}

private func hash(_ file: URL) throws -> SHA256.Digest {
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var digest = SHA256()
    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
        digest.update(data: data)
    }
    return digest.finalize()
}

private func registryIDForUSB(serial: String) -> UInt64? {
    var devices: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(devices) }
    while case let device = IOIteratorNext(devices), device != 0 {
        defer { IOObjectRelease(device) }
        let key = "USB Serial Number" as CFString
        let current = IORegistryEntryCreateCFProperty(device, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard current == serial else { continue }
        var id: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(device, &id) == KERN_SUCCESS {
            return id
        }
    }
    return nil
}

func unplugUSB(in temp: URL) async throws {
    let first: any DeviceConnection = try await USBDevice.connect()
    let info = try await first.info()
    guard let root = info.volumes.first?.root,
          let identity = info.fields.first(where: { $0.name == "USB 序列号" })?.value else {
        await first.close()
        throw CheckError.failed("需要读取测试设备的 USB 序列号。")
    }
    guard let registryID = registryIDForUSB(serial: identity) else {
        await first.close()
        throw CheckError.failed("无法跟踪设备的 USB 枚举状态。")
    }
    let roots = try await first.list(root)
    guard let download = roots.first(where: { $0.name == "Download" })?.folder else {
        await first.close()
        throw CheckError.failed("设备未公开 Download。")
    }
    let scratch = try await first.makeFolder(named: stressName(), in: download)
    let path = ["Download", scratch.name]
    let big = temp.appendingPathComponent("USB-拔线测试.dat")
    let tail = temp.appendingPathComponent("拔线后待传.txt")
    try fill(big)
    try Data("next in queue\n".utf8).write(to: tail)
    let jobs = try await TransferBatch.planUpload([big, tail], kind: .usb)
    let source = TransferExecutor(device: first, volumeRoot: root, devicePath: path)
    let results = Results()
    let probe = OSAllocatedUnfairLock(initialState: (paused: false, detached: false))
    let failure = await TransferBatch.run(jobs, executor: source, progress: { progress in
        guard progress.completed >= 8 * 1024 * 1024 else { return }
        let wait = probe.withLock { state in
            guard !state.paused else { return false }
            state.paused = true
            return true
        }
        if wait {
            FileHandle.standardOutput.write(Data("USB 拔线测试已暂停在 8 MiB，测试目录 \(scratch.name)\n".utf8))
            let deadline = ProcessInfo.processInfo.systemUptime + 300
            while ProcessInfo.processInfo.systemUptime < deadline {
                if registryIDForUSB(serial: identity) != registryID {
                    probe.withLock { $0.detached = true }
                    FileHandle.standardOutput.write(Data("macOS 已检测到传输中的 USB 设备离线或重新枚举。\n".utf8))
                    break
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }) { id, status in
        await results.record(id, status)
    }

    guard probe.withLock({ $0.detached }),
          let failure, TransferBatch.reconnectError(failure) else {
        try? await first.delete(scratch)
        await first.close()
        throw CheckError.failed("未检测到传输中的 USB 拔线。")
    }
    await first.close()
    guard case .interrupted? = await results.result(for: jobs[0].id) else {
        throw CheckError.failed("没有标记当前文件为中断。")
    }
    let following = await results.result(for: jobs[1].id)
    try require(following == nil, "拔线后仍启动了下一项。")
    FileHandle.standardOutput.write(Data("已捕获 USB 断开，正在等待重新插入。\n".utf8))

    let reconnectDeadline = ContinuousClock.now + .seconds(120)
    var lastConnectionError: Error?
    while ContinuousClock.now < reconnectDeadline {
        let reopened: USBDevice
        do {
            reopened = try await USBDevice.connect()
        } catch {
            lastConnectionError = error
            try await Task.sleep(for: .seconds(2))
            continue
        }
        do {
            let verified = try await reopened.info()
            try require(verified.fields.first(where: { $0.name == "USB 序列号" })?.value == identity, "USB 设备身份已变化。")
            guard let storage = verified.volumes.first(where: { $0.root == root }),
                  let parent = try await reopened.list(storage.root).first(where: { $0.name == "Download" })?.folder,
                  let fixture = try await reopened.list(parent).first(where: { $0.name == scratch.name }),
                  let folder = fixture.folder else { throw CheckError.failed("重插后无法找到测试目录。") }
            do {
                let interruptedFiles = try await reopened.list(folder)
                try require(interruptedFiles.isEmpty, "USB 拔线后存在残留文件：" + interruptedFiles.map(\.name).joined(separator: ", "))
                let retry = TransferExecutor(device: reopened, volumeRoot: root, devicePath: path)
                let second = await TransferBatch.run(jobs, executor: retry, progress: nil) { id, status in
                    await results.record(id, status)
                }
                try require(second == nil, "重新连接后的重试被中断。")
                let complete = try await reopened.list(folder)
                try require(complete.count == 2 && complete.contains(where: { $0.name == tail.lastPathComponent }),
                            "重试没有传完全部项目。")
                guard let returned = complete.first(where: { $0.name == big.lastPathComponent }),
                      let followUp = complete.first(where: { $0.name == tail.lastPathComponent }) else {
                    throw CheckError.failed("重传文件不在目标目录。")
                }
                let output = temp.appendingPathComponent("USB-readback.dat")
                try await reopened.download(returned, to: output, progress: nil)
                try require(try hash(output) == hash(big), "USB 重试结果 SHA-256 不一致。")
                let followUpOutput = temp.appendingPathComponent("USB-readback.txt")
                try await reopened.download(followUp, to: followUpOutput, progress: nil)
                try require(try Data(contentsOf: followUpOutput) == Data(contentsOf: tail), "等待项内容不一致。")
                try await reopened.delete(fixture)
                try require(try await !reopened.list(parent).contains(where: { $0.id == fixture.id }),
                            "拔线测试目录尚未清理。")
                print("USB：真机拔线、重插、无半成品、队列重试、SHA-256 校验及清理通过")
            } catch {
                try? await reopened.delete(fixture)
                throw error
            }
            await reopened.close()
            return
        } catch {
            await reopened.close()
            throw error
        }
    }
    let detail = lastConnectionError?.localizedDescription ?? "超时"
    throw CheckError.failed("未能重新打开 N10 Plus 的 MTP 会话（\(detail)）。测试目录：Download/\(scratch.name)")
}
