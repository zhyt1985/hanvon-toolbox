import Darwin
import Foundation

enum LANBeacon {
    private static let port: UInt16 = 49310

    static func probe(knownHosts: [String]) -> [DiscoveredCompanion] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }

        var enabled: Int32 = 1
        var timeout = timeval(tv_sec: 0, tv_usec: 350_000)
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            return []
        }

        let nonce = UUID().uuidString
        let query = Array("HANVON-DISCOVER/2 \(nonce)".utf8)
        var targets = broadcastAddresses()
        for host in knownHosts {
            var address = in_addr()
            if inet_pton(AF_INET, host, &address) == 1, isPrivate(address.s_addr) {
                targets.insert(address.s_addr)
            }
        }
        for addr in targets {
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = port.bigEndian
            destination.sin_addr.s_addr = addr
            withUnsafePointer(to: destination) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    _ = query.withUnsafeBytes { value in
                        sendto(fd, value.baseAddress, value.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var output: [DiscoveredCompanion] = []
        let until = ProcessInfo.processInfo.systemUptime + 0.7
        for _ in 0..<32 {
            guard ProcessInfo.processInfo.systemUptime < until else { break }
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var bytes = [UInt8](repeating: 0, count: 384)
            let count = withUnsafeMutablePointer(to: &sender) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    recvfrom(fd, &bytes, bytes.count, 0, socketAddress, &length)
                }
            }
            guard count > 0 else { break }
            let fields = String(decoding: bytes.prefix(count), as: UTF8.self).split(separator: " ", maxSplits: 4)
            guard fields.count == 5, fields[0] == "HANVON-HERE/2", fields[1] == nonce,
                  CompanionDevice.isDeviceID(String(fields[2])), let port = UInt16(fields[3]), port > 0,
                  sender.sin_port == Self.port.bigEndian, isPrivate(sender.sin_addr.s_addr),
                  let host = hostName(sender.sin_addr) else { continue }
            let name = fields[4].unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            guard !name.isEmpty else { continue }
            output.append(.init(
                id: String(fields[2]), name: String(String.UnicodeScalarView(name.prefix(80))),
                address: "https://\(host):\(port)"
            ))
        }
        return output
    }

    static func hostName(_ address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        guard result != nil else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func broadcastAddresses() -> Set<UInt32> {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var targets = Set<UInt32>()
        var next = interfaces
        while let interface = next?.pointee {
            next = interface.ifa_next
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_BROADCAST) != 0,
                  let address = interface.ifa_addr, let mask = interface.ifa_netmask,
                  Int32(address.pointee.sa_family) == AF_INET else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if isPrivate(ip), netmask != 0 {
                targets.insert(ip | ~netmask)
            }
        }
        return targets
    }

    private static func isPrivate(_ networkOrder: UInt32) -> Bool {
        let value = UInt32(bigEndian: networkOrder)
        return value & 0xFF000000 == 0x0A000000
            || value & 0xFFF00000 == 0xAC100000
            || value & 0xFFFF0000 == 0xC0A80000
    }
}
