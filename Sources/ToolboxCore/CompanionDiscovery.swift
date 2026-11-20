import Darwin
import Foundation

public struct DiscoveredCompanion: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let address: String

    public init(id: String, name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }
}

@MainActor
public final class CompanionDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    public static let type = "_hanvon-toolbox._tcp."

    private struct ServiceKey: Hashable {
        let name: String
        let type: String
        let domain: String

        init(_ service: NetService) {
            name = service.name
            type = service.type
            domain = service.domain
        }
    }

    private let browser = NetServiceBrowser()
    private var resolving: [ServiceKey: NetService] = [:]
    private var resolved: [ServiceKey: DiscoveredCompanion] = [:]
    private var started = false
    private var beaconTask: Task<Void, Never>?
    private var beacons: [String: (device: DiscoveredCompanion, lastSeen: TimeInterval)] = [:]
    private var lastPublished: [DiscoveredCompanion] = []
    public var knownHosts: [String] = []

    public var onChange: (([DiscoveredCompanion]) -> Void)?
    public var onError: ((String) -> Void)?

    public override init() {
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = false
    }

    public func start() {
        guard !started else { return }
        started = true
        browser.searchForServices(ofType: Self.type, inDomain: "local.")
        beaconTask = Task { [weak self] in
            while !Task.isCancelled, let hosts = self?.knownHosts {
                let replies = await Task.detached(priority: .utility) { LANBeacon.probe(knownHosts: hosts) }.value
                guard !Task.isCancelled else { return }
                self?.receivedBeacons(replies)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        beaconTask?.cancel()
        beaconTask = nil
        beacons.removeAll()
        browser.stop()
        resolving.values.forEach { $0.stop() }
        resolving.removeAll()
        resolved.removeAll()
        publish()
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard started else { return }
        let key = ServiceKey(service)
        resolving[key]?.stop()
        resolving[key] = service
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = ServiceKey(service)
        resolving.removeValue(forKey: key)?.stop()
        if resolved.removeValue(forKey: key) != nil { publish() }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        resolving.values.forEach { $0.stop() }
        resolving.removeAll()
        resolved.removeAll()
        publish()
        onError?("无法开始自动发现。请检查 macOS 的本地网络权限。")
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        let key = ServiceKey(sender)
        guard resolving[key] === sender,
              (1...65535).contains(sender.port),
              let data = sender.txtRecordData(),
              let version = NetService.dictionary(fromTXTRecord: data)["v"], String(data: version, encoding: .utf8) == "2",
              let identity = NetService.dictionary(fromTXTRecord: data)["id"], let id = String(data: identity, encoding: .utf8),
              CompanionDevice.isDeviceID(id),
              let host = sender.addresses?.compactMap(Self.ipv4).first else { return }
        let info = DiscoveredCompanion(id: id, name: sender.name, address: "https://\(host):\(sender.port)")
        guard resolved[key] != info else { return }
        resolved[key] = info
        publish()
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let key = ServiceKey(sender)
        if resolving[key] === sender {
            resolving[key]?.stop()
            resolving.removeValue(forKey: key)
            if resolved.removeValue(forKey: key) != nil { publish() }
        }
    }

    private func receivedBeacons(_ replies: [DiscoveredCompanion]) {
        let now = ProcessInfo.processInfo.systemUptime
        beacons = beacons.filter { now - $0.value.lastSeen < 7 }
        for reply in replies {
            beacons[reply.id] = (reply, now)
        }
        publish()
    }

    private func publish() {
        var devices = [String: DiscoveredCompanion]()
        for item in resolved.values.sorted(by: { $0.address < $1.address }) {
            devices[item.id] = item
        }
        for (id, entry) in beacons { devices[id] = entry.device }
        let ordered = devices.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        guard ordered != lastPublished else { return }
        lastPublished = ordered
        onChange?(ordered)
    }

    private static func ipv4(_ address: Data) -> String? {
        guard address.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        let value = address.withUnsafeBytes { $0.loadUnaligned(as: sockaddr_in.self) }
        guard Int32(value.sin_family) == AF_INET else { return nil }
        return LANBeacon.hostName(value.sin_addr)
    }
}
