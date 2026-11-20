import Foundation
import Security

enum KeychainStore {
    enum Operation: String {
        case read, save, remove
    }

    struct Reply: Codable {
        var status: OSStatus
        var data: Data? = nil
    }

    static func execute(_ operation: Operation, account: String, data: Data? = nil) -> Reply {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.hanvon.toolbox.wireless-management",
            kSecAttrAccount as String: account,
        ]
        switch operation {
        case .read:
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            return Reply(status: status, data: value as? Data)
        case .save:
            guard let data else { return Reply(status: errSecParam) }
            let values = [kSecValueData as String: data]
            let status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
            return Reply(status: status == errSecDuplicateItem
                ? SecItemUpdate(query as CFDictionary, values as CFDictionary)
                : status)
        case .remove:
            return Reply(status: SecItemDelete(query as CFDictionary))
        }
    }
}
