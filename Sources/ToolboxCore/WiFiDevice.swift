import Foundation

private final class WiFiRequestDelegate: NSObject, URLSessionTaskDelegate {
    let progress: ProgressUpdate?

    init(progress: ProgressUpdate? = nil) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesSent >= 0 else { return }
        progress?(TransferProgress(
            completed: UInt64(totalBytesSent),
            total: totalBytesExpectedToSend > 0 ? UInt64(totalBytesExpectedToSend) : nil
        ))
    }
}

public final class WiFiDevice: DeviceConnection, Sendable {
    private struct ListedItem: Decodable {
        let name: String
        let path: String
        let type: String
        let size: String?
    }

    private struct UploadedItem: Decodable {
        let name: String
    }

    public let kind = ConnectionKind.wifi
    private let base: URL
    private let session: URLSession
    private let apkUploadEnabled: Bool

    private init(base: URL, session: URLSession, apkUploadEnabled: Bool) {
        self.base = base
        self.session = session
        self.apkUploadEnabled = apkUploadEnabled
    }

    public static func connect(address: String) async throws -> WiFiDevice {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let unparsed = input.contains("://") ? input : "http://\(input)"
        guard let url = URL(string: unparsed), url.scheme?.lowercased() == "http",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              (url.path.isEmpty || url.path == "/"), url.query == nil, url.fragment == nil else {
            throw ToolboxError.message("请输入设备「Wi-Fi 传书」显示的完整 HTTP 地址。")
        }

        let session = makeSession(checkingConnection: true)
        defer { session.invalidateAndCancel() }
        let probe = WiFiDevice(base: url, session: session, apkUploadEnabled: false)
        do {
            _ = try await probe.list(.wifi(path: nil))
            let apk = try? await probe.get(Int.self, path: "/hasApkInstall")
            return WiFiDevice(base: url, session: makeSession(checkingConnection: false), apkUploadEnabled: apk == 1)
        } catch let error as URLError
            where [.notConnectedToInternet, .timedOut, .cannotConnectToHost].contains(error.code) {
            throw ToolboxError.message(
                "无法连接电纸书。请确认电纸书上的 Wi-Fi 传书正在运行，"
                + "并在 macOS「系统设置 → 隐私与安全性 → 本地网络」中允许汉王电纸书工具箱后重试。"
            )
        }
    }

    private static func makeSession(checkingConnection: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = checkingConnection ? 15 : 2 * 60 * 60
        configuration.waitsForConnectivity = checkingConnection
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: WiFiRequestDelegate(), delegateQueue: nil)
    }

    public func info() async throws -> DeviceInfo {
        DeviceInfo(
            name: "汉王 Wi-Fi 传书",
            fields: [
                .init("局域网地址", base.absoluteString),
                .init("连接服务", "原厂 Wi-Fi 传书"),
                .init("网页 APK 上传", apkUploadEnabled ? "设备声明支持" : "设备未启用"),
            ],
            volumes: [DeviceVolume(name: "内置存储（传书可见范围）", root: .wifi(path: nil))],
            supportsAPK: false, canManageFiles: false
        )
    }

    public func list(_ folder: DeviceFolder) async throws -> [DeviceItem] {
        guard case let .wifi(path) = folder else { throw ToolboxError.message("请选择 Wi-Fi 目录。") }
        let requestPath = try path.map { "/list/" + (try encodedDevicePath($0, encodeSlashes: false)) } ?? "/list/root"
        let entries = try await get([ListedItem].self, path: requestPath)
        var paths = Set<String>()
        return try entries.compactMap { entry in
            guard entry.type == "1" || entry.type == "2", paths.insert(entry.path).inserted else { return nil }
            _ = try encodedDevicePath(entry.path, encodeSlashes: false)
            try validateFileName(entry.name)
            return DeviceItem(
                id: .wifi(path: entry.path), name: entry.name,
                folder: entry.type == "1" ? .wifi(path: entry.path) : nil,
                sizeLabel: entry.size
            )
        }.sorted(by: listOrder)
    }

    public func download(_ item: DeviceItem, to destination: URL, progress: ProgressUpdate?) async throws {
        guard case let .wifi(path) = item.id, !item.isFolder else {
            throw ToolboxError.message("请选择可下载的 Wi-Fi 文件。")
        }
        try await download(path: "/download/" + encodedDevicePath(path, encodeSlashes: true), to: destination, progress: progress)
    }

    public func downloadUploaded(named name: String, to destination: URL) async throws {
        try validateFileName(name)
        try await download(path: "/files/" + encodeSegment(name), to: destination, progress: nil)
    }

    public func deleteUploaded(named name: String) async throws {
        try validateFileName(name)
        var request = URLRequest(url: try endpoint("/files/" + encodeSegment(name)))
        request.httpMethod = "POST"
        request.httpBody = Data("_method=delete".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try check(response)
        if try await uploadedNames().contains(name) {
            throw ToolboxError.invalidResponse("设备仍在上传列表中显示该文件。")
        }
    }

    public func upload(_ file: URL, to folder: DeviceFolder, progress: ProgressUpdate?) async throws {
        guard case .wifi = folder else { throw ToolboxError.message("请选择 Wi-Fi 传书连接。") }
        let name = file.lastPathComponent
        try validateFileName(name)
        guard file.pathExtension.lowercased() != "apk" else {
            throw ToolboxError.unsupported("请切换到 USB，使用「发送 APK」。")
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ToolboxError.unsupported("Wi-Fi 传书支持发送单个文件。")
        }
        let originalNames = try await uploadedNames()
        if originalNames.contains(where: { $0.compare(name, options: [.caseInsensitive]) == .orderedSame }) {
            throw ToolboxError.conflict(name)
        }

        let boundary = "HanvonToolbox-\(UUID().uuidString)"
        let body = try createTransferFile(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: body) }
        try makeUploadBody(source: file, destination: body, boundary: boundary, name: name)

        var request = URLRequest(url: try endpoint("/files"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, fromFile: body, delegate: WiFiRequestDelegate(progress: progress))
        try check(response)
        guard try await uploadedNames().contains(name) else {
            throw ToolboxError.invalidResponse("设备未在上传列表中确认该文件。请确认原厂传书支持该文件类型。")
        }
    }

    public func uploadedNames() async throws -> [String] {
        try await get([UploadedItem].self, path: "/files").map(\.name)
    }

    public func close() async {
        session.invalidateAndCancel()
    }

    private func download(path: String, to destination: URL, progress: ProgressUpdate?) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolboxError.conflict(destination.lastPathComponent)
        }
        progress?(TransferProgress(completed: 0, total: nil))
        let (downloaded, response) = try await session.download(for: URLRequest(url: endpoint(path)))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try check(response)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ToolboxError.invalidResponse("设备未返回完整文件。")
        }
        let size = UInt64(try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        if response.expectedContentLength >= 0, size != UInt64(response.expectedContentLength) {
            throw ToolboxError.invalidResponse("下载长度与设备声明不一致。")
        }
        let temp = try createTransferFile(in: destination.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.removeItem(at: temp)
        try FileManager.default.copyItem(at: downloaded, to: temp)
        try FileManager.default.moveItem(at: temp, to: destination)
        progress?(TransferProgress(completed: size, total: size))
    }

    private func makeUploadBody(source: URL, destination: URL, boundary: String, name: String) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let escapedName = name.replacingOccurrences(of: "\\", with: "%5C")
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
        let intro = "--\(boundary)\r\nContent-Disposition: form-data; name=\"fileName\"\r\n\r\n\(encodeSegment(name))\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"newfile\"; filename=\"\(escapedName)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"
        try output.write(contentsOf: Data(intro.utf8))
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.synchronize()
    }

    private func get<Value: Decodable>(_ type: Value.Type, path: String) async throws -> Value {
        let (data, response) = try await session.data(for: URLRequest(url: endpoint(path)))
        try check(response)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ToolboxError.invalidResponse("无线服务返回的格式与汉王传书接口不符。")
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ToolboxError.message("无法解析无线地址。")
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw ToolboxError.message("无法构建无线请求。") }
        return url
    }

    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw ToolboxError.invalidResponse("缺少 HTTP 状态。")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ToolboxError.message("Wi-Fi 传书请求失败（HTTP \(response.statusCode)）。")
        }
    }

    private func encodedDevicePath(_ path: String, encodeSlashes: Bool) throws -> String {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.contains("\0"), !pieces.contains(".."), !pieces.contains(".") else {
            throw ToolboxError.invalidResponse("无线服务返回了无效路径。")
        }
        return encodeSlashes ? encodeSegment(path) : pieces.map { encodeSegment(String($0)) }.joined(separator: "/")
    }

    private func encodeSegment(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
    }
}
