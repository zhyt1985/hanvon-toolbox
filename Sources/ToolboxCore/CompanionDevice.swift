import CryptoKit
import Foundation
import os
import Security

private final class CompanionTLS: NSObject, URLSessionDownloadDelegate {
    let pin: String
    let progress: ProgressUpdate?
    private let trustedHash = OSAllocatedUnfairLock<String?>(initialState: nil)
    var observedIdentity: String? { trustedHash.withLock { $0 } }

    init(pin: String, progress: ProgressUpdate? = nil) {
        self.pin = pin
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(.init(completed: UInt64(max(0, totalBytesWritten)),
                        total: totalBytesExpectedToWrite >= 0 ? UInt64(totalBytesExpectedToWrite) : nil))
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first, let key = SecCertificateCopyKey(leaf),
              let publicKey = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: publicKey).map { String(format: "%02X", $0) }.joined()
        if digest.hasPrefix(pin) {
            trustedHash.withLock { $0 = digest }
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
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
            total: totalBytesExpectedToSend >= 0 ? UInt64(totalBytesExpectedToSend) : nil
        ))
    }
}

public struct CompanionCredentials: Sendable {
    public let deviceID: String
    public let token: String

    public init(deviceID: String, token: String) {
        self.deviceID = deviceID
        self.token = token
    }
}

public final class CompanionDevice: DeviceConnection, Sendable {
    private struct Details: Decodable {
        struct ContentCapabilities: Decodable {
            let version: Int
            let sourceReads: Bool?
            let snapshotDownloads: Bool?
            enum CodingKeys: String, CodingKey { case version = "protocol", sourceReads, snapshotDownloads }
        }
        let protocolVersion: Int
        let id: String
        let root: String
        let rootID: String?
        let manufacturer: String
        let model: String
        let android: String
        let display: String
        let buildID: String
        let incremental: String
        let recoveryCleanup: Bool?
        let fileOperations: Bool?
        let resumableTransfers: Bool?
        let contentExport: ContentCapabilities?

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case id, root, rootID, manufacturer, model, android, display, buildID, incremental, recoveryCleanup, fileOperations, resumableTransfers, contentExport
        }
    }

    private struct Row: Decodable {
        let name: String
        let directory: Bool
        let size: UInt64?
        let modified: Double?
    }

    private struct ServerError: Decodable { let error: String }
    private struct Acknowledgement: Decodable { let ok: Bool }

    private struct PairingReply: Decodable {
        let id: String
        let token: String
    }

    private enum Authentication: Sendable {
        case pairing(String)
        case token(String)
    }

    public let kind = ConnectionKind.companion
    private let base: URL
    private let pin: String
    private let authentication: Authentication
    private let tls: CompanionTLS
    private let session: URLSession
    private let snapshotSupport = OSAllocatedUnfairLock(initialState: false)
    private let resumeIdentity = OSAllocatedUnfairLock<String?>(initialState: nil)

    private init(base: URL, pin: String, authentication: Authentication, checkingConnection: Bool = false) {
        self.base = base
        self.pin = pin
        self.authentication = authentication
        tls = CompanionTLS(pin: pin)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = checkingConnection ? 6 : 20
        config.timeoutIntervalForResource = checkingConnection ? 8 : 2 * 60 * 60
        session = URLSession(configuration: config, delegate: tls, delegateQueue: nil)
    }

    public static func pair(
        address: String, fingerprint: String, code: String, discoveredID: String? = nil
    ) async throws -> (CompanionDevice, CompanionCredentials) {
        let url = try addressURL(address)
        let pin = fingerprint.uppercased().filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pin.utf8.count == 16, isHex(pin),
              code.utf8.count == 8, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ToolboxError.message("请输入 16 位设备指纹和 8 位临时配对码。")
        }
        if let discoveredID, !discoveredID.hasPrefix(pin) {
            throw ToolboxError.message("输入的指纹与所选电纸书不符。请核对后重试。")
        }
        let probe = CompanionDevice(base: url, pin: discoveredID ?? pin, authentication: .pairing(code), checkingConnection: true)
        defer { probe.session.invalidateAndCancel() }
        do {
            var request = try probe.makeRequest("pair", query: [])
            request.httpMethod = "POST"
            let (data, response) = try await probe.session.data(for: request)
            try probe.check(response, data: data)
            let reply = try probe.decode(PairingReply.self, data: data)
            guard reply.id == probe.tls.observedIdentity, isDeviceID(reply.id), isToken(reply.token) else {
                throw ToolboxError.invalidResponse("配对响应的设备身份不一致。")
            }

            let creds = CompanionCredentials(deviceID: reply.id, token: reply.token)
            return (CompanionDevice(base: url, pin: creds.deviceID, authentication: .token(creds.token)), creds)
        } catch let error as URLError {
            throw connectionError(error)
        }
    }

    public static func reconnect(address: String, credentials: CompanionCredentials) async throws -> CompanionDevice {
        let url = try addressURL(address)
        guard isDeviceID(credentials.deviceID), isToken(credentials.token) else {
            throw ToolboxError.pairingExpired
        }
        let auth = Authentication.token(credentials.token)
        let probe = CompanionDevice(base: url, pin: credentials.deviceID, authentication: auth, checkingConnection: true)
        defer { probe.session.invalidateAndCancel() }
        do {
            _ = try await probe.info()
            return CompanionDevice(base: url, pin: credentials.deviceID, authentication: auth)
        } catch let error as URLError {
            throw connectionError(error)
        }
    }

    public static func connect(address: String, fingerprint: String, code: String) async throws -> CompanionDevice {
        try await pair(address: address, fingerprint: fingerprint, code: code).0
    }

    public static func isDeviceID(_ value: String) -> Bool {
        value.utf8.count == 64 && isHex(value)
    }

    private static func isHex(_ value: String) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }

    private static func isToken(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func addressURL(_ address: String) throws -> URL {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlText = address.contains("://") ? address : "https://\(address)"
        guard let url = URL(string: urlText), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, (url.path.isEmpty || url.path == "/"),
              url.query == nil, url.fragment == nil else {
            throw ToolboxError.message("请输入伴侣应用上显示的 HTTPS 地址和端口。")
        }
        return url
    }

    private static func connectionError(_ error: URLError) -> Error {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .userCancelledAuthentication, .secureConnectionFailed:
            ToolboxError.wirelessIdentityMismatch
        case .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed:
            ToolboxError.wirelessUnavailable
        default: error
        }
    }

    public func checkAvailability() async throws {
        var request = try makeRequest("info", query: [])
        request.timeoutInterval = 4
        do {
            let (data, response) = try await session.data(for: request)
            try check(response, data: data)
        } catch let error as URLError {
            throw Self.connectionError(error)
        }
    }

    public func info() async throws -> DeviceInfo {
        let details = try await get(Details.self, route: "info")
        snapshotSupport.withLock { $0 = details.contentExport?.version == 1 && details.contentExport?.snapshotDownloads == true }
        resumeIdentity.withLock { $0 = details.resumableTransfers == true ? details.rootID : nil }
        guard details.protocolVersion == 2, details.id == pin else {
            throw ToolboxError.unsupported("伴侣应用版本与 Mac 工具箱不兼容。")
        }
        return DeviceInfo(
            name: details.model,
            fields: [
                .init("厂商", details.manufacturer),
                .init("连接", base.absoluteString),
                .init("授权目录", details.root),
                .init("Android 版本", details.android),
                .init("构建显示号", details.display),
                .init("构建 ID", details.buildID),
                .init("增量构建号", details.incremental),
                .init("断点续传", details.resumableTransfers == true ? "普通文件上传与下载" : "伴侣 0.5.0 起支持"),
            ],
            volumes: [.init(name: details.root, root: .companion(path: ""), identity: details.rootID)],
            supportsAPK: true, canManageFiles: true, supportsRecoveryCleanup: details.recoveryCleanup == true,
            supportsFileOperations: details.fileOperations == true, supportsResumableTransfers: details.resumableTransfers == true,
            supportsContentSources: details.contentExport?.version == 1 && details.contentExport?.sourceReads == true,
            supportsContentSnapshots: details.contentExport?.version == 1 && details.contentExport?.snapshotDownloads == true
        )
    }

    public func list(_ folder: DeviceFolder) async throws -> [DeviceItem] {
        let parent = try folderPath(folder)
        let rows = try await get([Row].self, route: "list", query: [("path", parent)])
        return try rows.map { row in
            try validateFileName(row.name)
            let path = parent.isEmpty ? row.name : "\(parent)/\(row.name)"
            return DeviceItem(
                id: .companion(path: path), name: row.name,
                folder: row.directory ? .companion(path: path) : nil, size: row.size,
                modified: row.modified.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }.sorted(by: listOrder)
    }

    public func upload(_ file: URL, to folder: DeviceFolder, progress: ProgressUpdate?) async throws {
        try validateFileName(file.lastPathComponent)
        try await send(route: "upload", query: [("path", try folderPath(folder)), ("name", file.lastPathComponent)],
                       file: file, progress: progress)
    }

    private var resumeWire: ResumeWire {
        .init(send: { [self] method, route, query, body in
            var request = try makeRequest(route, query: query)
            request.httpMethod = method
            request.httpBody = body
            if method == "POST" { request.setValue(String(body?.count ?? 0), forHTTPHeaderField: "Content-Length") }
            let (data, response) = try await session.data(for: request)
            try check(response, data: data)
            return data
        })
    }

    public func uploadResumable(_ file: URL, to folder: DeviceFolder, transferID: UUID, progress: ProgressUpdate?) async throws {
        if resumeIdentity.withLock({ $0 }) == nil { _ = try await info() }
        guard resumeIdentity.withLock({ $0 }) != nil else {
            try await FileTransfers.uploadFile(file, to: folder, on: self, progress: progress); return
        }
        try await ResumableTransfers.upload(file, path: folderPath(folder), id: transferID, wire: resumeWire, progress: progress)
    }

    public func downloadResumable(_ item: DeviceItem, to destination: URL, transferID: UUID, progress: ProgressUpdate?) async throws {
        if resumeIdentity.withLock({ $0 }) == nil { _ = try await info() }
        guard let root = resumeIdentity.withLock({ $0 }) else { try await download(item, to: destination, progress: progress); return }
        try await ResumableTransfers.download(path: itemPath(item), destination: destination, scope: pin + "/" + root,
                                              id: transferID, wire: resumeWire, progress: progress)
    }

    public func discardResumable(_ transferID: UUID) async throws {
        guard let root = resumeIdentity.withLock({ $0 }) else { return }
        ResumableTransfers.discard(scope: pin + "/" + root, id: transferID)
        _ = try await resumeWire.send("POST", "resume/abort", [("id", transferID.uuidString)], nil)
    }

    public func makeFolder(named name: String, in folder: DeviceFolder) async throws -> DeviceItem {
        try validateFileName(name)
        let parent = try folderPath(folder)
        try await send(route: "folder", query: [("path", parent), ("name", name)])
        let entries = try await list(folder)
        guard let item = entries.first(where: { $0.isFolder && $0.name == name }) else {
            throw ToolboxError.invalidResponse("设备未在授权目录中显示新文件夹。")
        }
        return item
    }

    public func rename(_ item: DeviceItem, in folder: DeviceFolder, to name: String) async throws {
        try validateFileName(name)
        try await send(route: "rename", query: [("path", try itemPath(item)), ("name", name)])
    }

    public func cleanupRecoveryCopy(in folder: DeviceFolder, request: RecoveryCopyCleanup) async throws -> Bool {
        let result = try await getCleanupResult(folder, request: request)
        return result.removed
    }

    private struct CleanupResult: Decodable { let removed: Bool }

    private func getCleanupResult(_ folder: DeviceFolder, request: RecoveryCopyCleanup) async throws -> CleanupResult {
        var message = try makeRequest("recovery/cleanup", query: [
            ("path", try folderPath(folder)), ("id", request.backupID.uuidString),
            ("original", request.originalName), ("size", String(request.expected.byteCount)),
            ("sha256", request.expected.sha256.map { String(format: "%02x", $0) }.joined()),
        ])
        message.httpMethod = "POST"
        let (data, response) = try await session.data(for: message)
        try check(response, data: data)
        return try JSONDecoder().decode(CleanupResult.self, from: data)
    }

    public func relocate(_ item: DeviceItem, to folder: DeviceFolder, copying: Bool) async throws {
        try await send(route: copying ? "copy" : "move", query: [("path", try itemPath(item)), ("target", try folderPath(folder))])
    }

    public func delete(_ item: DeviceItem) async throws {
        try await send(route: "delete", query: [("path", try itemPath(item))])
    }

    public func requestAPKInstall(_ apk: URL, progress: ProgressUpdate?) async throws {
        try FileTransfers.validateAPK(apk)
        try await send(route: "apk", query: [("name", apk.lastPathComponent)], file: apk, progress: progress)
    }

    public func download(_ item: DeviceItem, to destination: URL, progress: ProgressUpdate?) async throws {
        guard !item.isFolder else { throw ToolboxError.message("请选择单个设备文件。") }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolboxError.conflict(destination.lastPathComponent)
        }
        let request = try makeRequest("file", query: [("path", try itemPath(item))])
        progress?(TransferProgress(completed: 0, total: item.size))
        let (downloaded, response) = try await session.download(for: request, delegate: CompanionTLS(pin: pin, progress: progress))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try check(response, data: nil)
        let size = UInt64(try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        if let expected = item.size, expected != size {
            throw ToolboxError.invalidResponse("下载大小与目录记录不符，请刷新目录后重试。")
        }
        let temp = try createTransferFile(in: destination.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.removeItem(at: temp)
        try FileManager.default.copyItem(at: downloaded, to: temp)
        try FileManager.default.moveItem(at: temp, to: destination)
        progress?(TransferProgress(completed: size, total: size))
    }

    public func close() async {
        session.invalidateAndCancel()
    }

    public func contentSources() async throws -> [CompanionContentSource] {
        let sources = try JSONDecoder().decode([CompanionContentSource].self,
            from: await contentRequest("GET", route: "sources", query: []))
        guard sources.count <= 8, Set(sources.map(\.id)).count == sources.count else {
            throw ToolboxError.invalidResponse("内容来源列表无效")
        }
        for source in sources { try source.validate() }
        return sources
    }

    public func requestContentAccess(_ source: CompanionContentSource) async throws -> CompanionContentAccessRequest {
        try source.validate()
        let data = try await contentRequest("POST", route: "access-requests", query: [("sourceID", source.id)])
        return try CompanionContentAccessRequest.decode(data, sourceID: source.id)
    }

    public func contentAccessStatus(_ request: CompanionContentAccessRequest) async throws -> CompanionContentAccessRequest {
        let data = try await contentRequest("GET", route: "access-request", query: [("id", request.id)])
        let status = try CompanionContentAccessRequest.decode(data, sourceID: request.sourceID)
        guard status.id == request.id, status.code == request.code else { throw ToolboxError.invalidResponse("授权请求身份已改变") }
        return status
    }

    public func contentDevice(_ source: CompanionContentSource) throws -> CompanionContentDevice {
        try source.validate()
        return try CompanionContentDevice(source: source, deviceID: pin, supportsSnapshots: snapshotSupport.withLock { $0 }, wire: .init(send: { [self] method, route, query, _ in
            try await contentRequest(method, route: route, query: query)
        }))
    }

    private func contentRequest(_ method: String, route: String, query: [(String, String)]) async throws -> Data {
        var request = try makeRequest("content/" + route, query: query)
        request.httpMethod = method
        if method == "POST" { request.setValue("0", forHTTPHeaderField: "Content-Length") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ToolboxError.invalidResponse("缺少内容响应状态") }
            if route.hasPrefix("snapshots"), !(200..<300).contains(http.statusCode),
               let failure = try? JSONDecoder().decode(ContentSnapshotFailure.self, from: data) {
                throw ContentSnapshotError(code: failure.error.code, message: failure.error.message)
            }
            if http.statusCode == 410 { throw ContentSnapshotError(code: "SNAPSHOT_EXPIRED", message: "快照已过期，请创建新的导出任务") }
            if http.statusCode == 403 { throw ContentSourceAccessError.denied }
            if http.statusCode == 409 { throw ContentSourceAccessError.changed }
            if http.statusCode == 404 { throw route == "sources" ? ContentSourceAccessError.unsupported : ContentSourceAccessError.missing }
            try check(response, data: data)
            guard data.count <= 2 * 1024 * 1024 else { throw ToolboxError.invalidResponse("内容来源响应超过限制") }
            return data
        } catch let error as URLError { throw Self.connectionError(error) }
    }

    private func get<Value: Decodable>(_ type: Value.Type, route: String, query: [(String, String)] = []) async throws -> Value {
        let (data, response) = try await session.data(for: makeRequest(route, query: query))
        try check(response, data: data)
        return try decode(type, data: data)
    }

    private func send(route: String, query: [(String, String)], file: URL? = nil, progress: ProgressUpdate? = nil) async throws {
        var request = try makeRequest(route, query: query)
        request.httpMethod = "POST"
        let result: (Data, URLResponse)
        if let file {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let length = values.fileSize, length >= 0 else {
                throw ToolboxError.message("请选择 Mac 上的普通文件。")
            }
            request.setValue(String(length), forHTTPHeaderField: "Content-Length")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            result = try await session.upload(for: request, fromFile: file, delegate: CompanionTLS(pin: pin, progress: progress))
        } else {
            result = try await session.data(for: request)
        }
        try check(result.1, data: result.0)
        guard try decode(Acknowledgement.self, data: result.0).ok else {
            throw ToolboxError.invalidResponse("电纸书没有确认操作。")
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ToolboxError.invalidResponse("伴侣应用响应格式错误。")
        }
    }

    private func makeRequest(_ route: String, query: [(String, String)]) throws -> URLRequest {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ToolboxError.message("无线管理地址无效。")
        }
        components.path = "/v1/\(route)"
        if !query.isEmpty {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            components.percentEncodedQuery = query.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            }.joined(separator: "&")
        }
        guard let endpoint = components.url else { throw ToolboxError.message("无法构建无线管理请求。") }
        var request = URLRequest(url: endpoint)
        switch authentication {
        case let .pairing(code): request.setValue(code, forHTTPHeaderField: "X-Hanvon-Code")
        case let .token(token): request.setValue(token, forHTTPHeaderField: "X-Hanvon-Token")
        }
        return request
    }

    private func check(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ToolboxError.invalidResponse("伴侣应用没有返回 HTTP 状态。")
        }
        if http.statusCode == 401, case .token = authentication {
            throw ToolboxError.pairingExpired
        }
        if http.statusCode == 404 { throw ToolboxError.remoteItemMissing }
        guard (200..<300).contains(http.statusCode) else {
            if let data, let error = try? JSONDecoder().decode(ServerError.self, from: data) {
                if http.statusCode == 409 && error.error == "目标中已有同名项目" {
                    let name = http.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                        .queryItems?.first(where: { $0.name == "name" })?.value
                    throw ToolboxError.conflict(name ?? "设备文件")
                }
                throw ToolboxError.message(error.error)
            }
            throw ToolboxError.message("伴侣应用返回 HTTP \(http.statusCode)。")
        }
    }

    private func folderPath(_ folder: DeviceFolder) throws -> String {
        guard case let .companion(path) = folder else { throw ToolboxError.message("请选择已授权的设备目录。") }
        return path
    }

    private func itemPath(_ item: DeviceItem) throws -> String {
        guard case let .companion(path) = item.id else { throw ToolboxError.message("请选择伴侣应用中的项目。") }
        return path
    }
}
