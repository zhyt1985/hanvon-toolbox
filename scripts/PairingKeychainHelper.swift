import Foundation
import Security

@main
enum PairingKeychainHelper {
    static func main() {
        let arguments = CommandLine.arguments
        guard authorizedParent(), arguments.count == 3,
              let operation = KeychainStore.Operation(rawValue: arguments[1]),
              arguments[2].utf8.count == 64,
              arguments[2].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
            exit(EX_NOPERM)
        }
        do {
            let data = operation == .save ? try readToken() : nil
            let reply = KeychainStore.execute(operation, account: arguments[2], data: data)
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(reply))
        } catch {
            exit(EX_IOERR)
        }
    }

    private static func readToken() throws -> Data {
        // Read to EOF because the complete request may arrive in multiple pipe writes.
        var token = Data()
        while let next = try FileHandle.standardInput.read(upToCount: 44 - token.count), !next.isEmpty {
            token.append(next)
            if token.count >= 44 { throw CocoaError(.fileReadCorruptFile) }
        }
        guard token.count == 43 else { throw CocoaError(.fileReadCorruptFile) }
        return token
    }

    private static func authorizedParent() -> Bool {
        let pid = getppid()
        var parent: SecCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        // Bind this request to the actual spawning process and its signed executable.
        guard pid > 1,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess,
              let parent,
              SecRequirementCreateWithString(pairingParentRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(parent, [], requirement) == errSecSuccess else {
            return false
        }
        return pid == getppid()
    }
}
