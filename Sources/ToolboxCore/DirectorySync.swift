import CryptoKit
import Darwin
import Foundation

public enum DirectorySync {
    public enum Direction: String, CaseIterable, Codable, Sendable {
        case toDevice, toMac
    }

    public struct LocalRoot: Codable, Equatable, Sendable {
        public let url: URL
        private let volume: Int32
        private let inode: UInt64

        public init(_ url: URL) throws {
            var metadata = stat()
            guard url.isFileURL, lstat(url.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR else {
                throw ToolboxError.message("Mac 同步目录不可用，请重新选择文件夹。")
            }
            self.url = url
            volume = metadata.st_dev
            inode = metadata.st_ino
        }

        public func validate() throws {
            guard self == (try? LocalRoot(url)) else {
                throw ToolboxError.message("Mac 同步目录已移动或被替换，请重新比较。")
            }
        }
    }

    public struct FileStamp: Codable, Equatable, Sendable {
        let size: UInt64
        let modified: Date?

        init?(_ values: URLResourceValues) {
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let count = values.fileSize, let size = UInt64(exactly: count) else { return nil }
            self.size = size
            modified = values.contentModificationDate
        }

        func validate(_ source: URL) throws {
            // URL resource values from directory enumeration may be cached.
            let fresh = URL(fileURLWithPath: source.path(percentEncoded: false))
            let values = try fresh.resourceValues(forKeys: DirectorySync.localKeys)
            guard self == FileStamp(values) else {
                throw ToolboxError.message("Mac 源文件已改变，请重新比较。")
            }
        }
    }

    public struct Fingerprint: Codable, Equatable, Sendable {
        public let byteCount: UInt64
        public let sha256: Data
    }

    public struct Row: Identifiable, Sendable {
        public enum BaselineChange: String, Sendable {
            case macModified = "仅 Mac 修改"
            case deviceModified = "仅电纸书修改"
            case bothModified = "两边都修改"
            case missingOnMac = "Mac 端缺失"
            case missingOnDevice = "电纸书端缺失"
        }
        public enum Kind: String, CaseIterable, Sendable {
            case copyFile = "复制文件"
            case createFolder = "新建空文件夹"
            case keepDestination = "保留目标已有"
            case identical = "已一致"
            case conflict = "跳过冲突"
            case excluded = "忽略项目"
        }

        public let id = UUID()
        public let path: String
        public let kind: Kind
        public let detail: String?
        public let step: TransferStep?
        public internal(set) var canVerifyContent = false
        public internal(set) var fingerprint: Fingerprint?
        public internal(set) var baselineChange: BaselineChange?
        public internal(set) var macFingerprint: Fingerprint?
        public internal(set) var deviceFingerprint: Fingerprint?
    }

    private struct Entry {
        enum Content {
            case localFolder(URL)
            case remoteFolder(DeviceFolder)
            case localFile(FileStamp)
            case remoteFile(DeviceItem)
            case excluded(String)
        }

        let name: String
        let content: Content

        var isFolder: Bool {
            switch content {
            case .localFolder, .remoteFolder: true
            default: false
            }
        }
    }

    private struct Comparison {
        let direction: Direction
        let verifyContents: Bool
        let captureFingerprints: Bool
        let baseline: [String: Fingerprint]
        let trackedPaths: Set<String>

        init(direction: Direction, verifyContents: Bool, captureFingerprints: Bool, baseline: [String: Fingerprint]) {
            self.direction = direction
            self.verifyContents = verifyContents
            self.captureFingerprints = captureFingerprints
            self.baseline = baseline
            var paths = Set<String>()
            for path in baseline.keys {
                var current = ""
                for component in path.split(separator: "/") {
                    current += current.isEmpty ? String(component) : "/\(component)"
                    paths.insert(nameKey(current))
                }
            }
            trackedPaths = paths
        }
    }

    private static let localKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isHiddenKey, .isPackageKey,
        .fileSizeKey, .contentModificationDateKey,
    ]

    public static func compare(
        _ direction: Direction, local: LocalRoot, remote: DeviceFolder, on device: any DeviceConnection,
        verifyContents: Bool = false, baseline: [String: Fingerprint] = [:], captureFingerprints: Bool = false
    ) async throws -> [Row] {
        guard device.kind != .wifi else {
            throw ToolboxError.unsupported("目录同步支持 USB 和无线管理。")
        }
        try local.validate()
        var rows: [Row] = []
        let comparison = Comparison(direction: direction, verifyContents: verifyContents,
                                    captureFingerprints: captureFingerprints, baseline: baseline)
        try await compareFolder(local: local.url, remote: remote, on: device, comparison: comparison,
                                parents: [], visited: [], rows: &rows)
        return rows
    }

    private static func compareFolder(
        local: URL?, remote: DeviceFolder?, on device: any DeviceConnection, comparison: Comparison,
        parents: [String], visited: Set<DeviceFolder>, rows: inout [Row]
    ) async throws {
        try Task.checkCancellation()
        if let remote, visited.contains(remote) {
            throw ToolboxError.invalidResponse("设备返回了循环目录，无法比较。")
        }
        let mac = try local.map(listLocal) ?? []
        let reader: [Entry]
        if let remote {
            reader = try await device.list(remote).map { item in
                let content: Entry.Content
                if item.name.hasPrefix(".") { content = .excluded("隐藏项目") }
                else if let folder = item.folder { content = .remoteFolder(folder) }
                else { content = .remoteFile(item) }
                return Entry(name: item.name, content: content)
            }
        } else {
            reader = []
        }
        let direction = comparison.direction
        let source = Dictionary(grouping: direction == .toDevice ? mac : reader) { nameKey($0.name) }
        let target = Dictionary(grouping: direction == .toDevice ? reader : mac) { nameKey($0.name) }
        let keys = Set(source.keys).union(target.keys).sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        let descendants = remote.map { visited.union([$0]) } ?? visited

        if keys.isEmpty, !parents.isEmpty, (direction == .toDevice ? remote == nil : local == nil) {
            let path = parents.joined(separator: "/")
            let action = TransferStep.Action.syncEmptyFolder(path: parents, direction: direction)
            rows.append(Row(path: path, kind: .createFolder, detail: nil, step: .init(name: path, action: action)))
        }

        for key in keys {
            try Task.checkCancellation()
            let origins = source[key] ?? []
            let destinations = target[key] ?? []
            if origins.isEmpty || destinations.isEmpty {
                let side = origins.isEmpty ? destinations : origins
                if side.count == 1, let entry = side.first {
                    let path = (parents + [entry.name]).joined(separator: "/")
                    if comparison.trackedPaths.contains(nameKey(path)) {
                        let missingOnMac = direction == .toDevice ? origins.isEmpty : destinations.isEmpty
                        let change: Row.BaselineChange = missingOnMac ? .missingOnMac : .missingOnDevice
                        rows.append(Row(path: path, kind: .conflict,
                                        detail: entry.isFolder ? "含基线记录，保留仍存在的一侧" : "已记录基线，保留仍存在的一侧",
                                        step: nil, baselineChange: change))
                        continue
                    }
                }
            }
            guard let origin = origins.first else {
                for entry in destinations {
                    rows.append(Row(path: (parents + [entry.name]).joined(separator: "/"),
                                    kind: .keepDestination, detail: nil, step: nil))
                }
                continue
            }
            let components = parents + [origin.name]
            let path = components.joined(separator: "/")
            if origins.count == 1, case .excluded(let reason) = origin.content {
                rows.append(Row(path: path, kind: .excluded, detail: reason, step: nil))
                continue
            }
            let destination = destinations.first
            let conflict: String?
            if origins.count > 1 || destinations.count > 1 {
                conflict = "同一目录有多个同名或大小写相近的项目"
            } else if let destination, origin.name != destination.name {
                conflict = "目标已有「\(destination.name)」，名称仅大小写有别"
            } else if let destination, origin.isFolder != destination.isFolder {
                conflict = "两侧同名项目的类型不同"
            } else {
                conflict = nil
            }
            if let conflict {
                rows.append(Row(path: path, kind: .conflict, detail: conflict, step: nil))
                continue
            }
            guard (try? validateFileName(origin.name)) != nil else {
                rows.append(Row(path: path, kind: .excluded, detail: "文件名超出传输支持范围", step: nil))
                continue
            }
            if let destination, !origin.isFolder {
                let macEntry = direction == .toDevice ? origin : destination
                let readerEntry = direction == .toDevice ? destination : origin
                let row = try await compareFiles(mac: macEntry, reader: readerEntry, directory: local,
                                                 path: path, device: device, comparison: comparison)
                rows.append(row)
                continue
            }
            switch origin.content {
            case .excluded:
                break
            case .localFolder(let child):
                var deviceChild: DeviceFolder?
                if case .remoteFolder(let folder) = destination?.content { deviceChild = folder }
                try await compareFolder(local: child, remote: deviceChild, on: device, comparison: comparison,
                                        parents: components, visited: descendants, rows: &rows)
            case .remoteFolder(let child):
                var localChild: URL?
                if case .localFolder(let folder) = destination?.content { localChild = folder }
                try await compareFolder(local: localChild, remote: child, on: device, comparison: comparison,
                                        parents: components, visited: descendants, rows: &rows)
            case .localFile(let stamp):
                let step = TransferStep(name: path, action: .syncUpload(path: components, stamp: stamp))
                rows.append(Row(path: path, kind: .copyFile, detail: nil, step: step))
            case .remoteFile(let item):
                let step = TransferStep(name: path, action: .download(path: components, expectedSize: item.size))
                rows.append(Row(path: path, kind: .copyFile, detail: nil, step: step))
            }
        }
    }

    private static func listLocal(_ folder: URL) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(localKeys)).map { url in
            let name = url.lastPathComponent
            let values = try url.resourceValues(forKeys: localKeys)
            let content: Entry.Content
            if name.hasPrefix(".") || values.isHidden == true { content = .excluded("隐藏项目") }
            else if values.isSymbolicLink == true { content = .excluded("符号链接") }
            else if values.isPackage == true { content = .excluded("macOS 文件包") }
            else if values.isDirectory == true { content = .localFolder(url) }
            else if let stamp = FileStamp(values) { content = .localFile(stamp) }
            else { content = .excluded("非常规文件") }
            return Entry(name: name, content: content)
        }
    }

    public static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func compareFiles(
        mac: Entry, reader: Entry, directory: URL?, path: String,
        device: any DeviceConnection, comparison: Comparison
    ) async throws -> Row {
        guard let directory, case let .localFile(stamp) = mac.content,
              case let .remoteFile(item) = reader.content else {
            return Row(path: path, kind: .conflict, detail: "两侧同名项目的类型不同", step: nil)
        }
        guard let remoteSize = item.size else {
            return Row(path: path, kind: .conflict, detail: "设备端文件大小未知", step: nil)
        }
        let previous = comparison.baseline[path]
        let sameSize = stamp.size == remoteSize
        let canVerify = sameSize || previous != nil || comparison.captureFingerprints
        guard comparison.verifyContents, canVerify else {
            let detail = sameSize ? "大小相同，内容未校验" : "同名文件大小不同"
            return Row(path: path, kind: .conflict, detail: detail, step: nil, canVerifyContent: canVerify)
        }
        do {
            let localFile = directory.appendingPathComponent(mac.name)
            try stamp.validate(localFile)
            // A size differing from the baseline already proves a change for that side.
            let macHash = comparison.captureFingerprints || sameSize || previous?.byteCount == stamp.size
                ? try digest(of: localFile) : nil
            let readerHash = comparison.captureFingerprints || sameSize || previous?.byteCount == remoteSize
                ? try await remoteDigest(of: item, expectedSize: remoteSize, device: device) : nil
            try stamp.validate(localFile)
            if let macHash, macHash == readerHash {
                let fingerprint = Fingerprint(byteCount: stamp.size, sha256: macHash)
                return Row(path: path, kind: .identical, detail: "SHA-256 一致", step: nil, fingerprint: fingerprint)
            }
            let change: Row.BaselineChange?
            if let previous {
                let macChanged = stamp.size != previous.byteCount || macHash != previous.sha256
                let deviceChanged = remoteSize != previous.byteCount || readerHash != previous.sha256
                change = macChanged && deviceChanged ? .bothModified : (macChanged ? .macModified : .deviceModified)
            } else {
                change = nil
            }
            return Row(path: path, kind: .conflict, detail: "内容不同", step: nil, baselineChange: change,
                       macFingerprint: macHash.map { Fingerprint(byteCount: stamp.size, sha256: $0) },
                       deviceFingerprint: readerHash.map { Fingerprint(byteCount: remoteSize, sha256: $0) })
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || TransferBatch.reconnectError(error) { throw error }
            return Row(path: path, kind: .conflict, detail: "未能校验内容。\(error.localizedDescription)",
                       step: nil, canVerifyContent: true)
        }
    }

    public static func fingerprint(of file: URL) throws -> Fingerprint {
        let file = URL(fileURLWithPath: file.path)
        let values = try file.resourceValues(forKeys: localKeys)
        guard let stamp = FileStamp(values) else { throw ToolboxError.message("请选择普通文件。") }
        let hash = try digest(of: file)
        try stamp.validate(file)
        return Fingerprint(byteCount: stamp.size, sha256: hash)
    }

    private static func remoteDigest(of item: DeviceItem, expectedSize: UInt64,
                                     device: any DeviceConnection) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloaded = directory.appendingPathComponent("compare")
        try await device.download(item, to: downloaded, progress: nil)
        try Task.checkCancellation()
        let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.flatMap({ UInt64(exactly: $0) }) == expectedSize else {
            throw ToolboxError.message("设备端文件已改变，请重新比较。")
        }
        return try digest(of: downloaded)
    }

    private static func digest(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty else { break }
            hash.update(data: bytes)
        }
        return Data(hash.finalize())
    }
}
