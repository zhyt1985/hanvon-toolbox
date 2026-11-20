import Foundation

public actor ContentExportStore {
    public struct LoadResult: Sendable {
        public let jobs: [ContentExportJob]
        public let warning: String?
    }
    private let directory: URL
    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "HanvonToolbox/ContentExport/Jobs")) {
        self.directory = directory
    }
    public func save(_ job: ContentExportJob) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: job.id.uuidString + ".json")
        try JSONEncoder().encode(job).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func load() throws -> [ContentExportJob] {
        try loadReport().jobs
    }
    public func loadReport() throws -> LoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else { return .init(jobs: [], warning: nil) }
        var jobs: [ContentExportJob] = []
        var unreadable = 0
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let size = values.fileSize, size < 16 * 1024 * 1024,
                  var job = try? JSONDecoder().decode(ContentExportJob.self, from: Data(contentsOf: file)),
                  job.schemaVersion == 1, file.lastPathComponent == job.id.uuidString + ".json" else {
                unreadable += 1
                continue
            }
            for i in job.rows.indices where [.preparing, .transferring, .verifying].contains(job.rows[i].state) {
                job.rows[i].state = .interrupted
                job.rows[i].message = "工具箱退出时仍在导出，连接原来源后可重试"
            }
            jobs.append(job)
        }
        return .init(jobs: jobs.sorted { $0.createdAt > $1.createdAt },
                     warning: unreadable > 0 ? "有 \(unreadable) 项内容导出记录无法读取；原记录已保留" : nil)
    }
}

public enum ContentExporter {
    public typealias RecordUpdate = @Sendable (ContentExportJob) async throws -> Void

    public static func run(_ initial: ContentExportJob, root: DeviceFolder, device: any DeviceConnection,
                           store: ContentExportStore, progress: ProgressUpdate? = nil,
                           report: @escaping RecordUpdate) async throws -> ContentExportJob {
        var job = initial
        guard job.schemaVersion == 1, job.output.isFileURL, job.source.connection == device.kind else {
            throw ToolboxError.message("导出任务与当前连接不匹配")
        }
        try validateOutputRoot(job)
        job.paused = false
        try await store.save(job); try await report(job)
        for index in job.rows.indices where !job.rows[index].state.isFinished {
            var readingDevice: any DeviceConnection = device
            do {
                try Task.checkCancellation()
                guard !job.rows[index].item.protected else { throw ToolboxError.unsupported("此记录受保护或保护状态未知，未导出") }
                try ContentReader.validateComponent(job.rows[index].outputName)
                let existing = job.output.appending(path: job.rows[index].outputName)
                if FileManager.default.fileExists(atPath: existing.path) {
                    try await validatePublished(job: job, row: job.rows[index], directory: existing)
                    job.rows[index].state = job.source.kind == .notes ? .limited : .completed
                    job.rows[index].message = "已核对之前发布的完整副本"
                    if let companion = device as? CompanionContentDevice, let reference = job.rows[index].snapshot {
                        do { try await companion.releaseSnapshot(reference); job.rows[index].snapshot?.released = true }
                        catch let error as ContentSnapshotError where error.code == "SNAPSHOT_EXPIRED" { job.rows[index].snapshot?.released = true }
                        catch { }
                    }
                    try await store.save(job); try await report(job)
                    try write(job, to: job.output.appending(path: "result.json"))
                    continue
                }
                if let companion = device as? CompanionContentDevice, companion.supportsSnapshots {
                    job.rows[index].state = .preparing
                    job.rows[index].message = "电纸书正在准备固定副本，完成后开始下载；请保持无线管理开启"
                    if job.rows[index].snapshot == nil { job.rows[index].snapshot = ContentSnapshotReference() }
                    try await store.save(job); try await report(job)
                    let snapshot = try await companion.prepareSnapshot(job.rows[index].snapshot!, source: job.source,
                        item: job.rows[index].item, progress: progress)
                    job.rows[index].snapshot = snapshot.reference
                    readingDevice = snapshot
                    try await store.save(job); try await report(job)
                } else if job.rows[index].snapshot != nil {
                    throw ToolboxError.unsupported("此任务需要支持快照的伴侣 0.7.0 或更新版本")
                }
                try await ContentReader.validateNoteRevision(job.source, root: root, device: readingDevice)
                job.rows[index].state = .preparing; job.rows[index].message = nil
                try await store.save(job); try await report(job)
                let inventory = try await ContentReader.inventory(item: job.rows[index].item, source: job.source, root: root, device: readingDevice)
                if let previous = job.rows[index].resources {
                    try sameInventory(previous, job.rows[index].directories, inventory.files, inventory.directories)
                } else {
                    job.rows[index].resources = inventory.files
                    job.rows[index].directories = inventory.directories
                }
                try await store.save(job); try await report(job)
                let outputName = job.rows[index].outputName
                try ContentReader.validateComponent(outputName)
                let final = job.output.appending(path: outputName)
                if FileManager.default.fileExists(atPath: final.path) {
                    try await validatePublished(job: job, row: job.rows[index], directory: final)
                } else {
                    let staging = job.output.appending(path: ".pending-" + job.rows[index].id.uuidString)
                    try privateDirectory(staging)
                    let raw = staging.appending(path: "raw")
                    try privateDirectory(raw)
                    let knownBytes = job.rows[index].resources!.compactMap(\.size).reduce(UInt64(0)) { partial, size in
                        let next = partial.addingReportingOverflow(size)
                        return next.overflow ? UInt64.max : next.partialValue
                    }
                    let required = knownBytes.multipliedReportingOverflow(by: 2)
                    let free = (try FileManager.default.attributesOfFileSystem(forPath: raw.path)[.systemFreeSize] as? NSNumber)?.uint64Value
                    guard !required.overflow, let free, free > 64 * 1024 * 1024,
                          free - 64 * 1024 * 1024 >= required.partialValue else {
                        throw ToolboxError.message("Mac 可用空间不足，未继续下载；请释放空间或分批导出")
                    }
                    for path in job.rows[index].directories { _ = try nested(path, in: raw, create: true) }
                    for fileIndex in job.rows[index].resources!.indices {
                        try Task.checkCancellation()
                        var resource = job.rows[index].resources![fileIndex]
                        let relativeParent = Array(resource.path.dropLast())
                        let parent = try nested(relativeParent, in: raw, create: true)
                        guard let name = resource.path.last else { throw ToolboxError.message("无效资源路径") }
                        try ContentReader.validateComponent(name)
                        let file = parent.appending(path: name)
                        let remote = try await ContentReader.resource(resource, item: job.rows[index].item, source: job.source, root: root, device: readingDevice)
                        job.rows[index].state = .transferring
                        try await store.save(job); try await report(job)
                        if FileManager.default.fileExists(atPath: file.path) {
                            try regularFile(file)
                            let cachedHash = try await ContentReader.fingerprint(file)
                            if !(resource.downloaded && resource.sha256 == cachedHash) {
                                try FileManager.default.removeItem(at: file)
                            }
                        }
                        if !FileManager.default.fileExists(atPath: file.path) {
                            try await readingDevice.downloadResumable(remote, to: file, transferID: resource.id, progress: progress)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        }
                        let hash = try await ContentReader.fingerprint(file)
                        if let snapshot = readingDevice as? CompanionSnapshotDevice,
                           hash != (try snapshot.expectedHash(for: remote)) {
                            throw ContentSnapshotError(code: "REQUEST_CONFLICT", message: "本机缓存与设备固定副本不同，请重新创建任务")
                        }
                        if let expected = resource.sha256, hash != expected { throw ToolboxError.message("导出缓存已改变，请重新创建任务") }
                        job.rows[index].state = .verifying
                        try await store.save(job); try await report(job)
                        if !(readingDevice is CompanionSnapshotDevice) {
                            let check = staging.appending(path: ".verify-" + UUID().uuidString)
                            do {
                                let current = try await ContentReader.resource(resource, item: job.rows[index].item, source: job.source, root: root, device: readingDevice)
                                try await readingDevice.download(current, to: check, progress: nil)
                                guard hash == (try await ContentReader.fingerprint(check)) else {
                                    throw ToolboxError.message("源文件在读取期间发生变化，请重新扫描并创建任务")
                                }
                                try FileManager.default.removeItem(at: check)
                            } catch { try? FileManager.default.removeItem(at: check); throw error }
                        }
                        resource.sha256 = hash; resource.downloaded = true
                        job.rows[index].resources![fileIndex] = resource
                        try await store.save(job); try await report(job)
                    }
                    let after = try await ContentReader.inventory(item: job.rows[index].item, source: job.source, root: root, device: readingDevice)
                    try sameInventory(job.rows[index].resources!, job.rows[index].directories, after.files, after.directories)
                    try await ContentReader.validateNoteRevision(job.source, root: root, device: readingDevice)
                    try Task.checkCancellation()
                    try validateRawTree(raw, resources: job.rows[index].resources!, directories: job.rows[index].directories)
                    guard Set(try FileManager.default.contentsOfDirectory(atPath: staging.path)).isSubset(of: ["raw", "item.json"]) else {
                        throw ToolboxError.message("导出暂存目录出现额外文件，未发布")
                    }
                    let limitations = job.source.kind == .notes
                        ? ["仅保存所选原始目录与该项索引。跨目录资源和笔记页面格式尚未完整适配，不承诺可恢复或可阅读。"]
                        : ["收集来源文件，不执行内容转换。"]
                    var manifest = ContentExportManifest(schemaVersion: 1, jobID: job.id, rowID: job.rows[index].id,
                        createdAt: Date(), source: job.source, item: job.rows[index].item,
                        resources: job.rows[index].resources!, directories: job.rows[index].directories,
                        capture: "stableReadObserved", limitations: limitations)
                    manifest.snapshot = job.rows[index].snapshot
                    try write(manifest, to: staging.appending(path: "item.json"))
                    try validateDirectory(job.output)
                    try FileManager.default.moveItem(at: staging, to: final)
                }
                job.rows[index].state = job.source.kind == .notes ? .limited : .completed
                job.rows[index].message = job.source.kind == .notes ? "原始目录已校验；不包含未识别的跨目录资源，不承诺可恢复" : (job.rows[index].snapshot == nil ? "文件与源读取结果 SHA-256 一致" : "文件与设备固定副本 SHA-256 一致")
                if let companion = device as? CompanionContentDevice, let reference = job.rows[index].snapshot {
                    do { try await companion.releaseSnapshot(reference); job.rows[index].snapshot?.released = true }
                    catch { /* Lease expiry reclaims it; a later content operation retries release. */ }
                }
            } catch {
                var contentAccessEnded = error is ContentSourceAccessError
                if job.source.wirelessSource != nil, case .pairingExpired? = error as? ToolboxError { contentAccessEnded = true }
                let snapshotInvalid = (error as? ContentSnapshotError)?.invalidatesCache == true
                if contentAccessEnded || snapshotInvalid {
                    for pending in job.rows.indices where !job.rows[pending].state.isFinished {
                        for resource in job.rows[pending].resources ?? [] {
                            if let companion = device as? CompanionContentDevice, let reference = job.rows[pending].snapshot {
                                companion.discardSnapshotCache(reference, transferID: resource.id)
                            } else { try? await readingDevice.discardResumable(resource.id) }
                        }
                        try clearTemporary(job, row: job.rows[pending])
                        job.rows[pending].state = .failed
                        job.rows[pending].message = error.localizedDescription
                    }
                    job.paused = false
                    try await store.save(job); try await report(job)
                    try write(job, to: job.output.appending(path: "result.json"))
                    return job
                }
                let interrupted = error is CancellationError || Task.isCancelled || TransferBatch.reconnectError(error)
                job.rows[index].state = interrupted ? .interrupted : .failed
                job.rows[index].message = error is CancellationError || Task.isCancelled ? "已暂停，连接原来源后可继续" : error.localizedDescription
                job.paused = interrupted
                try await store.save(job); try await report(job)
                try write(job, to: job.output.appending(path: "result.json"))
                if interrupted { return job }
            }
            try await store.save(job); try await report(job)
            try write(job, to: job.output.appending(path: "result.json"))
        }
        return job
    }

    public static func releaseFinishedSnapshots(_ initial: ContentExportJob, device: CompanionContentDevice,
                                               store: ContentExportStore) async throws -> ContentExportJob {
        var job = initial
        for index in job.rows.indices where job.rows[index].state.isFinished {
            guard let reference = job.rows[index].snapshot, !reference.released else { continue }
            do { try await device.releaseSnapshot(reference); job.rows[index].snapshot?.released = true }
            catch let error as ContentSnapshotError where error.code == "SNAPSHOT_EXPIRED" { job.rows[index].snapshot?.released = true }
            catch is ContentSourceAccessError { job.rows[index].snapshot?.released = true }
            catch { continue }
        }
        try await store.save(job)
        return job
    }

    public static func cancel(_ initial: ContentExportJob, store: ContentExportStore) async throws -> ContentExportJob {
        var job = initial
        if FileManager.default.fileExists(atPath: job.output.path) { try validateOutputRoot(job) }
        for i in job.rows.indices where !job.rows[i].state.isFinished {
            job.rows[i].state = .cancelled; job.rows[i].message = "已取消；已完成的正式输出保留"
            try clearTemporary(job, row: job.rows[i])
        }
        job.paused = false
        try await store.save(job)
        if FileManager.default.fileExists(atPath: job.output.path) { try write(job, to: job.output.appending(path: "result.json")) }
        return job
    }

    public static func invalidateAccess(_ initial: ContentExportJob, store: ContentExportStore) async throws -> ContentExportJob {
        var job = initial
        if FileManager.default.fileExists(atPath: job.output.path) { try validateOutputRoot(job) }
        for i in job.rows.indices where !job.rows[i].state.isFinished {
            try clearTemporary(job, row: job.rows[i])
            job.rows[i].state = .failed
            job.rows[i].message = "内容来源授权已撤销或版本已变化；未发布缓存已清理，请重新授权并扫描"
        }
        job.paused = false
        try await store.save(job)
        if FileManager.default.fileExists(atPath: job.output.path) { try write(job, to: job.output.appending(path: "result.json")) }
        return job
    }

    private static func sameInventory(_ a: [ContentExportResource], _ ad: [[String]],
                                      _ b: [ContentExportResource], _ bd: [[String]]) throws {
        guard ad == bd, a.count == b.count, zip(a, b).allSatisfy({ $0.path == $1.path && $0.size == $1.size && $0.modified == $1.modified }) else {
            throw ToolboxError.message("来源目录的成员、大小或时间已变化，请重新扫描")
        }
    }

    private static func clearTemporary(_ job: ContentExportJob, row: ContentExportRow) throws {
        for resource in row.resources ?? [] {
            if let identity = job.source.resumeIdentity, let volume = job.source.resumeVolume {
                FileTransfers.clearResumableCache(deviceIdentity: identity, volumeIdentity: volume + (row.snapshot?.cacheSuffix ?? ""), transferID: resource.id)
            }
        }
        let stage = job.output.appending(path: ".pending-" + row.id.uuidString)
        if FileManager.default.fileExists(atPath: stage.path) {
            try validateOutputRoot(job); try validateDirectory(stage)
            try FileManager.default.removeItem(at: stage)
        }
    }

    private static func validatePublished(job: ContentExportJob, row: ContentExportRow, directory: URL) async throws {
        try validateDirectory(directory)
        let manifestFile = directory.appending(path: "item.json")
        try regularFile(manifestFile)
        let manifest = try JSONDecoder().decode(ContentExportManifest.self, from: Data(contentsOf: manifestFile))
        guard manifest.schemaVersion == 1, manifest.jobID == job.id, manifest.rowID == row.id,
              manifest.source == job.source, manifest.item == row.item, manifest.resources == row.resources,
              manifest.directories == row.directories,
              manifest.snapshot?.id == row.snapshot?.id, manifest.snapshot?.manifestSHA256 == row.snapshot?.manifestSHA256 else { throw ToolboxError.conflict(row.outputName) }
        try validateRawTree(directory.appending(path: "raw"), resources: manifest.resources, directories: manifest.directories)
        for resource in manifest.resources {
            let file = try nested(Array(resource.path.dropLast()), in: directory.appending(path: "raw"), create: false)
                .appending(path: resource.path.last ?? "")
            try regularFile(file)
            guard resource.downloaded, let hash = resource.sha256, hash == (try await ContentReader.fingerprint(file)) else {
                throw ToolboxError.message("已发布目录被改变，未覆盖；请重新创建导出任务")
            }
        }
    }

    private static func validateOutputRoot(_ job: ContentExportJob) throws {
        let parent = job.output.deletingLastPathComponent()
        guard parent.standardizedFileURL == parent.resolvingSymlinksInPath().standardizedFileURL,
              job.output.lastPathComponent == "内容导出-" + job.id.uuidString else {
            throw ToolboxError.message("导出目标目录已改变")
        }
        try validateDirectory(parent)
        if FileManager.default.fileExists(atPath: job.output.path) {
            try validateDirectory(job.output)
            let owner = job.output.appending(path: ".owner.json")
            try regularFile(owner)
            guard try String(contentsOf: owner, encoding: .utf8) == job.id.uuidString else { throw ToolboxError.conflict(job.output.lastPathComponent) }
        } else {
            try privateDirectory(job.output)
            try Data(job.id.uuidString.utf8).write(to: job.output.appending(path: ".owner.json"), options: .withoutOverwriting)
        }
    }

    private static func validateRawTree(_ raw: URL, resources: [ContentExportResource], directories: [[String]]) throws {
        try validateDirectory(raw)
        let expected = Set(resources.map { $0.path.joined(separator: "/") } + directories.map { $0.joined(separator: "/") })
        let rootComponents = raw.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var observed = Set<String>()
        guard let iterator = FileManager.default.enumerator(at: raw, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
            throw ToolboxError.message("无法核对输出目录")
        }
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw ToolboxError.message("输出包含符号链接，未发布") }
            let components = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard Array(components.prefix(rootComponents.count)) == rootComponents else {
                throw ToolboxError.message("输出资源离开了暂存目录，未发布")
            }
            let name = components.dropFirst(rootComponents.count).joined(separator: "/")
            guard expected.contains(name) else { throw ToolboxError.message("输出包含计划外文件，未发布") }
            if values.isDirectory != true { try regularFile(file) }
            observed.insert(name)
        }
        guard expected == observed else { throw ToolboxError.message("输出目录有资源缺失，未发布") }
    }

    private static func privateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try validateDirectory(url) }
        else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    }
    private static func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ToolboxError.message("导出位置不是安全的普通目录") }
    }
    private static func regularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ToolboxError.message("导出位置包含符号链接或特殊文件") }
    }
    private static func nested(_ path: [String], in root: URL, create: Bool) throws -> URL {
        try validateDirectory(root)
        var directory = root
        for component in path {
            try ContentReader.validateComponent(component)
            directory.append(path: component)
            if create { try privateDirectory(directory) } else { try validateDirectory(directory) }
        }
        return directory
    }
    private static func write<T: Encodable>(_ value: T, to file: URL) throws {
        try validateDirectory(file.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: file.path) { try regularFile(file) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
