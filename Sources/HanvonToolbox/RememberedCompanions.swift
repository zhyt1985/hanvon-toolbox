import Foundation
import Security
import ToolboxCore

struct RememberedCompanion: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    var browseLocation: CompanionBrowseLocation?

    static let defaultsKey = "hanvon.rememberedCompanions"

    static func load() -> [RememberedCompanion] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let items = try? JSONDecoder().decode([RememberedCompanion].self, from: data) else { return [] }
        return items.filter { CompanionDevice.isDeviceID($0.id) }
    }

    static func save(_ items: [RememberedCompanion]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

enum PairingKeychain {
    struct AuthorizationRequired: LocalizedError {
        var errorDescription: String? {
            "macOS 未允许工具箱访问配对钥匙串。请重新连接，并在系统提示中授权。"
        }
    }

    static func save(_ credentials: CompanionCredentials) async throws {
        try await Task.detached {
            let reply = try execute(.save, account: credentials.deviceID, data: Data(credentials.token.utf8))
            try check(reply.status)
        }.value
    }

    static func read(_ id: String) async throws -> CompanionCredentials {
        try await Task.detached {
            let reply = try execute(.read, account: id)
            if reply.status == errSecItemNotFound { throw ToolboxError.pairingExpired }
            try check(reply.status)
            guard let bytes = reply.data, let token = String(data: bytes, encoding: .utf8) else {
                throw ToolboxError.pairingExpired
            }
            return CompanionCredentials(deviceID: id, token: token)
        }.value
    }

    static func remove(_ id: String) async throws {
        try await Task.detached {
            let reply = try execute(.remove, account: id)
            if reply.status != errSecItemNotFound { try check(reply.status) }
        }.value
    }

    private static func execute(_ operation: KeychainStore.Operation, account: String, data: Data? = nil) throws -> KeychainStore.Reply {
        guard Bundle.main.object(forInfoDictionaryKey: "HanvonUsesPairingKeychainHelper") as? Bool == true else {
            return KeychainStore.execute(operation, account: account, data: data)
        }

        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/HanvonPairingKeychain")
        process.arguments = [operation.rawValue, account]
        let input = Pipe()
        if let data {
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try input.fileHandleForWriting.close()
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ToolboxError.message("无法启动配对钥匙串组件。请从完整的 Mac 工具箱应用打开。")
        }
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolboxError.message("配对钥匙串组件启动失败（\(process.terminationStatus)）。请检查工具箱签名。")
        }
        return try JSONDecoder().decode(KeychainStore.Reply.self, from: bytes)
    }

    private static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess:
            return
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            throw AuthorizationRequired()
        default:
            throw ToolboxError.message("无法访问 macOS 钥匙串（\(status)）。")
        }
    }
}
